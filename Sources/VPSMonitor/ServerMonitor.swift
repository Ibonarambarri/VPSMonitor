import Foundation

/// Watches one VPS: polls it on its own schedule, keeps its history and raises its alerts.
@MainActor
final class ServerMonitor: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var profile: VPSProfile
    @Published private(set) var metrics: ServerMetrics?
    @Published private(set) var projects: [CoolifyProject] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var sshError: String?
    @Published private(set) var coolifyError: String?
    @Published private(set) var sshAvailable: Bool?
    @Published private(set) var coolifyAvailable: Bool?
    @Published private(set) var history: MetricsHistory
    @Published private(set) var alerts: [MonitorAlert] = []
    @Published private(set) var isLive = false

    var token: String
    var configuration: MonitorConfiguration { profile.configuration }

    private var preferences: MonitorPreferences
    private var loopTask: Task<Void, Never>?
    private var sshConsecutiveFailures = 0
    private var coolifyConsecutiveFailures = 0
    private var lastCoolifyCheck: Date?
    private var lastAttempt: Date?
    private var lastHistorySave = Date.distantPast
    private var alertEngine = AlertEngine()
    private let historyStore: MetricsHistoryStore
    /// Called with notifications to show; the owner decides whether they are enabled.
    var onNotifications: ([AlertNotification]) -> Void = { _ in }

    init(profile: VPSProfile, token: String, preferences: MonitorPreferences, historyStore: MetricsHistoryStore,
         legacySamples: [MetricSample] = []) {
        id = profile.id
        self.profile = profile
        self.token = token
        self.preferences = preferences
        self.historyStore = historyStore
        var samples = historyStore.load()
        if samples.isEmpty && !historyStore.exists { samples = legacySamples }
        history = MetricsHistory(persisted: samples)
    }

    var currentInterval: TimeInterval {
        if isLive { return MonitorPreferences.liveRefreshInterval }
        // Re-check failures sooner so an outage is confirmed quickly.
        if sshConsecutiveFailures > 0 || coolifyConsecutiveFailures > 0 { return min(preferences.refreshInterval, 15) }
        return preferences.refreshInterval
    }

    var availability: Double? { history.availability() }

    var errorMessages: [String] { [sshError, coolifyError].compactMap { $0 } }

    var isConfigured: Bool { !configuration.sshHost.isEmpty || !configuration.coolifyURL.isEmpty }

    var overallState: HealthState {
        if let severity = alertEngine.overallSeverity { return severity }
        if sshAvailable == false || coolifyAvailable == false { return .warning }
        return lastUpdated == nil ? .unknown : .healthy
    }

    // MARK: - Control

    func start() { restartLoop() }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func setLive(_ live: Bool) {
        let live = live && preferences.liveWhileOpen && !configuration.sshHost.isEmpty
        guard live != isLive else { return }
        isLive = live
        restartLoop()
    }

    func refreshNow(after delay: TimeInterval? = nil) {
        lastCoolifyCheck = nil
        restartLoop(refreshNow: true, initialDelay: delay)
    }

    /// The Mac slept or changed network: the shared SSH connection is gone and the
    /// first failures are not the server's fault.
    func recoverConnection(after delay: TimeInterval) {
        sshConsecutiveFailures = 0
        coolifyConsecutiveFailures = 0
        let configuration = configuration
        Task { [weak self] in
            await SSHMetricsClient().resetConnection(configuration: configuration)
            self?.refreshNow(after: delay)
        }
    }

    func update(profile: VPSProfile, token: String, preferences: MonitorPreferences) {
        let previous = self.profile.configuration
        let connectionChanged = previous.sshHost != profile.configuration.sshHost
            || previous.sshUser != profile.configuration.sshUser
            || previous.sshPort != profile.configuration.sshPort
            || previous.sshKeyPath != profile.configuration.sshKeyPath
        let coolifyChanged = previous.coolifyURL != profile.configuration.coolifyURL || self.token != token
        self.profile = profile
        self.token = token
        self.preferences = preferences
        if previous.sshHost != profile.configuration.sshHost {
            // A different server: its past is not this one's.
            metrics = nil
            history = MetricsHistory()
            historyStore.clear()
        }
        if connectionChanged {
            Task { await SSHMetricsClient().resetConnection(configuration: previous) }
            sshAvailable = nil
            sshError = nil
        }
        if coolifyChanged {
            projects = []
            coolifyAvailable = nil
            coolifyError = nil
        }
        sshConsecutiveFailures = 0
        coolifyConsecutiveFailures = 0
        alertEngine.reset()
        alerts = []
        isLive = isLive && preferences.liveWhileOpen && !profile.configuration.sshHost.isEmpty
        refreshNow()
    }

    func persistHistory() {
        historyStore.save(history.persisted)
    }

    func removeStoredData() {
        stop()
        historyStore.clear()
        let configuration = configuration
        Task { await SSHMetricsClient().resetConnection(configuration: configuration) }
    }

    // MARK: - Checks

    private func restartLoop(refreshNow: Bool = false, initialDelay: TimeInterval? = nil) {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            var force = refreshNow
            if let initialDelay {
                do { try await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000)) } catch { return }
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
        guard !isRefreshing, isConfigured else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let configuration = configuration
        let token = token
        let preferences = preferences
        let now = Date()
        let checkSSH = !configuration.sshHost.isEmpty
        let coolifyInterval = max(30, preferences.refreshInterval)
        let checkCoolify = !configuration.coolifyURL.isEmpty &&
            (lastCoolifyCheck.map { now.timeIntervalSince($0) >= coolifyInterval - 1 || coolifyConsecutiveFailures > 0 } ?? true)

        async let sshResult: Result<ServerMetrics, Error>? = checkSSH ? Self.capture { try await SSHMetricsClient().fetch(configuration: configuration) } : nil
        async let coolifyResult: Result<[CoolifyProject], Error>? = checkCoolify ? Self.capture { try await CoolifyClient().fetchProjects(baseURL: configuration.coolifyURL, token: token) } : nil
        let (ssh, coolify) = await (sshResult, coolifyResult)

        // Settings may have changed while the checks were running.
        guard configuration == self.configuration, token == self.token, !Task.isCancelled else { return }

        var snapshot = AlertSnapshot(thresholds: (preferences.cpuAlertThreshold, preferences.memoryAlertThreshold, preferences.diskAlertThreshold))
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
        if !notifications.isEmpty { onNotifications(notifications) }

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
}
