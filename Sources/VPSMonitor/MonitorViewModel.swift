import AppKit
import Foundation
import Network

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published var configuration: MonitorConfiguration
    @Published var token = ""
    @Published private(set) var metrics: ServerMetrics?
    @Published private(set) var projects: [CoolifyProject] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var sshError: String?
    @Published private(set) var coolifyError: String?
    @Published private(set) var settingsError: String?
    @Published private(set) var sshAvailable: Bool?
    @Published private(set) var coolifyAvailable: Bool?
    @Published private(set) var history: MetricsHistory
    @Published private(set) var alerts: [MonitorAlert] = []
    @Published private(set) var isOffline = false
    @Published private(set) var isPanelVisible = false
    @Published private(set) var isLaunchingSSH = false
    @Published private(set) var sshLaunchErrorMessage: String?
    @Published var historyRange: HistoryRange = .hour

    private var loopTask: Task<Void, Never>?
    private var sshConsecutiveFailures = 0
    private var coolifyConsecutiveFailures = 0
    private var lastCoolifyCheck: Date?
    private var lastAttempt: Date?
    private var lastHistorySave = Date.distantPast
    private var alertEngine = AlertEngine()
    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let historyStore: MetricsHistoryStore
    private let usesKeychain: Bool

    var canOpenSSHSession: Bool {
        SSHSessionLauncher().isConfigured(configuration: configuration)
    }

    var isLive: Bool { isPanelVisible && configuration.liveWhileOpen && !configuration.sshHost.isEmpty }

    var currentInterval: TimeInterval {
        if isLive { return MonitorConfiguration.liveRefreshInterval }
        // Re-check failures sooner so an outage is confirmed quickly.
        if sshConsecutiveFailures > 0 || coolifyConsecutiveFailures > 0 { return min(configuration.refreshInterval, 15) }
        return configuration.refreshInterval
    }

    var availability: Double? { history.availability() }

    var errorMessages: [String] {
        [settingsError, sshError, coolifyError].compactMap { $0 }
    }

    var overallState: HealthState {
        if let severity = alertEngine.overallSeverity { return severity }
        if sshAvailable == false || coolifyAvailable == false { return .warning }
        return lastUpdated == nil ? .unknown : .healthy
    }

    // Use a stable suite so Debug, Release and future .app builds share settings.
    init(defaults: UserDefaults = UserDefaults(suiteName: "com.vpsmonitor.app") ?? .standard,
         historyStore: MetricsHistoryStore = .standard,
         usesKeychain: Bool = true) {
        self.defaults = defaults
        self.historyStore = historyStore
        self.usesKeychain = usesKeychain
        configuration = ConfigurationStore(defaults: defaults).load()
        token = usesKeychain ? KeychainStore.read(account: "coolify-token") : ""
        history = MetricsHistory(persisted: historyStore.load())
        NotificationPresenter.shared.install()
        if configuration.notificationsEnabled { AlertNotifier.requestAuthorization() }
        startObservingSystem()
        restartLoop()
    }

    func save() {
        let previous = ConfigurationStore(defaults: defaults).load()
        ConfigurationStore(defaults: defaults).save(configuration)
        do { if usesKeychain { try KeychainStore.save(token, account: "coolify-token") }; settingsError = nil }
        catch { settingsError = "No se pudo guardar el token en Keychain: \(error.localizedDescription)" }
        if configuration.notificationsEnabled && !previous.notificationsEnabled { AlertNotifier.requestAuthorization() }
        if previous.sshHost != configuration.sshHost || previous.sshUser != configuration.sshUser || previous.sshPort != configuration.sshPort {
            Task { await SSHMetricsClient().resetConnection(configuration: previous) }
            metrics = nil
            history = MetricsHistory()
            historyStore.clear()
        }
        sshConsecutiveFailures = 0
        coolifyConsecutiveFailures = 0
        lastCoolifyCheck = nil
        alertEngine.reset()
        alerts = []
        restartLoop(refreshNow: true)
    }

    func refreshNow() {
        lastCoolifyCheck = nil
        restartLoop(refreshNow: true)
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        // Opening the panel refreshes right away if the data is older than the live cadence.
        restartLoop()
    }

    func openSSHSession() {
        guard !isLaunchingSSH else { return }
        let configuration = configuration
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
        historyStore.save(history.persisted)
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Scheduling

    private func restartLoop(refreshNow: Bool = false, initialDelay: TimeInterval? = nil) {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            var force = refreshNow
            if let initialDelay {
                try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
            }
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = self.lastAttempt.map { Date().timeIntervalSince($0) } ?? .infinity
                let wait = force ? 0 : max(self.currentInterval - elapsed, 0)
                if wait > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } catch { return }
                }
                // A check cancelled by a restart may still be winding down.
                while self.isRefreshing {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                }
                guard !Task.isCancelled else { return }
                force = false
                await self.performRefresh()
                self.lastAttempt = Date()
            }
        }
    }

    private func performRefresh() async {
        guard !isRefreshing else { return }
        guard !isOffline else {
            // The Mac has no network: don't blame the server. Try again later.
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let configuration = configuration
        let token = token
        let now = Date()
        let checkSSH = !configuration.sshHost.isEmpty
        let coolifyInterval = max(30, configuration.refreshInterval)
        let checkCoolify = !configuration.coolifyURL.isEmpty &&
            (lastCoolifyCheck.map { now.timeIntervalSince($0) >= coolifyInterval - 1 || coolifyConsecutiveFailures > 0 } ?? true)

        async let sshResult: Result<ServerMetrics, Error>? = checkSSH ? Self.capture { try await SSHMetricsClient().fetch(configuration: configuration) } : nil
        async let coolifyResult: Result<[CoolifyProject], Error>? = checkCoolify ? Self.capture { try await CoolifyClient().fetchProjects(baseURL: configuration.coolifyURL, token: token) } : nil
        let (ssh, coolify) = await (sshResult, coolifyResult)

        // Settings may have changed while the checks were running.
        guard configuration == self.configuration, !Task.isCancelled else { return }

        var snapshot = AlertSnapshot(thresholds: (configuration.cpuAlertThreshold, configuration.memoryAlertThreshold, configuration.diskAlertThreshold))
        switch ssh {
        case .success(let newMetrics):
            metrics = newMetrics
            sshAvailable = true
            sshError = nil
            sshConsecutiveFailures = 0
            history.append(MetricSample(date: Date(), metrics: newMetrics))
            snapshot.metrics = newMetrics
        case .failure(let error):
            sshAvailable = false
            sshError = error.localizedDescription
            sshConsecutiveFailures += 1
            // A single failed check is retried before it counts as downtime.
            if sshConsecutiveFailures >= AlertEngine.failuresBeforeDown {
                history.append(MetricSample(date: Date(), metrics: nil))
            }
        case nil:
            if !checkSSH {
                sshAvailable = nil
                sshError = nil
                sshConsecutiveFailures = 0
            }
        }
        if checkSSH {
            snapshot.sshFailures = sshConsecutiveFailures
            snapshot.sshError = sshError
        }

        switch coolify {
        case .success(let newProjects):
            projects = newProjects
            coolifyAvailable = true
            coolifyError = nil
            coolifyConsecutiveFailures = 0
            lastCoolifyCheck = Date()
            snapshot.projects = newProjects
        case .failure(let error):
            coolifyAvailable = false
            coolifyError = error.localizedDescription
            coolifyConsecutiveFailures += 1
            lastCoolifyCheck = Date()
        case nil:
            if configuration.coolifyURL.isEmpty {
                projects = []
                coolifyAvailable = nil
                coolifyError = nil
                coolifyConsecutiveFailures = 0
            } else if coolifyAvailable == true {
                snapshot.projects = projects
            }
        }
        if !configuration.coolifyURL.isEmpty { snapshot.coolifyFailures = coolifyConsecutiveFailures }

        let notifications = alertEngine.evaluate(snapshot)
        alerts = alertEngine.activeAlerts
        if configuration.notificationsEnabled { notifications.forEach(AlertNotifier.post) }

        lastUpdated = Date()
        if Date().timeIntervalSince(lastHistorySave) >= 60 {
            lastHistorySave = Date()
            let samples = history.persisted
            let store = historyStore
            Task.detached(priority: .utility) { store.save(samples) }
        }
    }

    private static func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    // MARK: - System events

    private func startObservingSystem() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(offline: offline) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.vpsmonitor.network"))

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.loopTask?.cancel() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.didWake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.historyStore.save(self.history.persisted)
            }
        })
    }

    private func networkChanged(offline: Bool) {
        guard offline != isOffline else { return }
        isOffline = offline
        if !offline {
            let configuration = configuration
            Task { [weak self] in
                await SSHMetricsClient().resetConnection(configuration: configuration)
                self?.restartLoop(refreshNow: true, initialDelay: 2)
            }
        }
    }

    private func didWake() {
        // The shared SSH connection did not survive sleep; failures right after waking are not outages.
        sshConsecutiveFailures = 0
        coolifyConsecutiveFailures = 0
        let configuration = configuration
        Task { [weak self] in
            await SSHMetricsClient().resetConnection(configuration: configuration)
            self?.restartLoop(refreshNow: true, initialDelay: 5)
        }
    }
}
