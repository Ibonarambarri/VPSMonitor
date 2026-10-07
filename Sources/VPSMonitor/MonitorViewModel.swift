import AppKit
import Combine
import Foundation
import Network

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var profiles: [VPSProfile]
    @Published private(set) var selectedProfileID: UUID
    @Published private(set) var preferences: MonitorPreferences
    @Published private(set) var monitors: [UUID: ServerMonitor] = [:]
    @Published private(set) var settingsError: String?
    @Published private(set) var isOffline = false
    @Published private(set) var isPanelVisible = false
    @Published private(set) var isLaunchingSSH = false
    @Published private(set) var sshLaunchErrorMessage: String?
    @Published var historyRange: HistoryRange = .hour

    private let store: ConfigurationStore
    private let historyStoreProvider: (UUID) -> MetricsHistoryStore
    private let usesKeychain: Bool
    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var monitorSubscriptions: [UUID: AnyCancellable] = [:]

    // Use a stable suite so Debug, Release and future .app builds share settings.
    init(defaults: UserDefaults = UserDefaults(suiteName: "com.vpsmonitor.app") ?? .standard,
         historyStoreProvider: @escaping (UUID) -> MetricsHistoryStore = MetricsHistoryStore.standard(for:),
         usesKeychain: Bool = true) {
        store = ConfigurationStore(defaults: defaults)
        self.historyStoreProvider = historyStoreProvider
        self.usesKeychain = usesKeychain
        let profiles = store.loadProfiles()
        self.profiles = profiles
        selectedProfileID = store.loadSelectedProfileID().flatMap { id in profiles.first { $0.id == id }?.id } ?? profiles[0].id
        preferences = store.loadPreferences()

        NotificationPresenter.shared.install()
        if preferences.notificationsEnabled { AlertNotifier.requestAuthorization() }
        startObservingSystem()

        for profile in profiles { addMonitor(for: profile, token: "") }
        guard usesKeychain else {
            monitors.values.forEach { $0.start() }
            return
        }
        // Reading Keychain may show a permission prompt after an update, so keep it off the main thread.
        let ids = profiles.map(\.id)
        Task { @MainActor [weak self] in
            let tokens = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: ids.map { ($0, KeychainStore.token(for: $0)) })
            }.value
            guard let self else { return }
            for (id, token) in tokens { self.monitors[id]?.token = token }
            if !self.isOffline { self.monitors.values.forEach { $0.start() } }
        }
    }

    var selectedProfile: VPSProfile { profiles.first { $0.id == selectedProfileID } ?? profiles[0] }

    var selectedMonitor: ServerMonitor? { monitors[selectedProfileID] }

    var orderedMonitors: [ServerMonitor] { profiles.compactMap { monitors[$0.id] } }

    var isRefreshingAny: Bool { monitors.values.contains { $0.isRefreshing } }

    var canOpenSSHSession: Bool {
        SSHSessionLauncher().isConfigured(configuration: selectedProfile.configuration)
    }

    /// The menu bar shows the worst state across every VPS.
    var overallState: HealthState {
        let states = orderedMonitors.filter(\.isConfigured).map(\.overallState)
        if let worst = states.max(by: { $0.rank < $1.rank }), worst.rank > HealthState.healthy.rank { return worst }
        if states.contains(.healthy) { return .healthy }
        return .unknown
    }

    func token(for id: UUID) -> String { monitors[id]?.token ?? "" }

    func select(_ id: UUID) {
        guard id != selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        store.saveSelectedProfileID(id)
        sshLaunchErrorMessage = nil
        updateLiveMode()
    }

    func save(profiles newProfiles: [VPSProfile], tokens: [UUID: String], selectedID: UUID, preferences newPreferences: MonitorPreferences) {
        guard !newProfiles.isEmpty else { return }
        let previousPreferences = preferences
        store.saveProfiles(newProfiles)
        store.savePreferences(newPreferences)
        settingsError = nil

        for profile in newProfiles {
            let token = tokens[profile.id] ?? ""
            // Only touch Keychain when the token changed, to avoid needless permission prompts.
            if usesKeychain && token != (monitors[profile.id]?.token ?? "") {
                do { try KeychainStore.save(token, for: profile.id) }
                catch { settingsError = "No se pudo guardar el token de \(profile.displayName) en Keychain: \(error.localizedDescription)" }
            }
        }
        for removed in profiles where !newProfiles.contains(where: { $0.id == removed.id }) {
            monitors[removed.id]?.removeStoredData()
            monitors[removed.id] = nil
            monitorSubscriptions[removed.id] = nil
            if usesKeychain { KeychainStore.deleteToken(for: removed.id) }
        }

        profiles = newProfiles
        preferences = newPreferences
        for profile in newProfiles {
            let token = tokens[profile.id] ?? ""
            if let monitor = monitors[profile.id] {
                monitor.update(profile: profile, token: token, preferences: newPreferences)
            } else {
                addMonitor(for: profile, token: token)
                monitors[profile.id]?.start()
            }
        }
        selectedProfileID = newProfiles.contains { $0.id == selectedID } ? selectedID : newProfiles[0].id
        store.saveSelectedProfileID(selectedProfileID)
        if newPreferences.notificationsEnabled && !previousPreferences.notificationsEnabled { AlertNotifier.requestAuthorization() }
        updateLiveMode()
    }

    func refreshSelected() { selectedMonitor?.refreshNow() }

    func refreshAll() { monitors.values.forEach { $0.refreshNow() } }

    func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        updateLiveMode()
    }

    func openSSHSession() {
        guard !isLaunchingSSH else { return }
        let configuration = selectedProfile.configuration
        isLaunchingSSH = true
        sshLaunchErrorMessage = nil
        Task { @MainActor [weak self] in
            defer { self?.isLaunchingSSH = false }
            do {
                try await SSHSessionLauncher().launch(configuration: configuration)
            } catch {
                self?.sshLaunchErrorMessage = error.localizedDescription
            }
        }
    }

    func quit() {
        monitors.values.forEach { $0.persistHistory() }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Private

    private func addMonitor(for profile: VPSProfile, token: String) {
        let monitor = ServerMonitor(profile: profile, token: token, preferences: preferences,
                                    historyStore: historyStoreProvider(profile.id),
                                    legacySamples: store.legacySamples(for: profile.id))
        monitor.onNotifications = { [weak self, weak monitor] notifications in
            guard let self, let monitor, self.preferences.notificationsEnabled else { return }
            let prefix = self.profiles.count > 1 ? monitor.profile.displayName + ": " : ""
            for notification in notifications {
                AlertNotifier.post(AlertNotification(id: "\(monitor.id).\(notification.id)",
                                                     title: prefix + notification.title, body: notification.body))
            }
        }
        // Republish child changes so views reading through this model stay current.
        monitorSubscriptions[profile.id] = monitor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        monitors[profile.id] = monitor
    }

    private func updateLiveMode() {
        for monitor in monitors.values {
            monitor.setLive(isPanelVisible && monitor.id == selectedProfileID)
        }
    }

    private func startObservingSystem() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(offline: offline) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.vpsmonitor.network"))

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.monitors.values.forEach { $0.stop() } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.monitors.values.forEach { $0.recoverConnection(after: 5) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.monitors.values.forEach { $0.persistHistory() }
            }
        })
    }

    private func networkChanged(offline: Bool) {
        guard offline != isOffline else { return }
        isOffline = offline
        if offline {
            // Without network every check would fail; don't blame the servers.
            monitors.values.forEach { $0.stop() }
        } else {
            monitors.values.forEach { $0.recoverConnection(after: 2) }
        }
    }
}
