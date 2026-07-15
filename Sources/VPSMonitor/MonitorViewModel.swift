import AppKit
import Foundation

struct MetricSample: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let memory: Double?
}

struct ChartMetricSample: Identifiable {
    var id: Date { date }
    let date: Date
    let cpu: Double
    let memory: Double
}

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published var configuration: MonitorConfiguration
    @Published var token = ""
    @Published private(set) var metrics: ServerMetrics?
    @Published private(set) var projects: [CoolifyProject] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var sshAvailable: Bool?
    @Published private(set) var coolifyAvailable: Bool?
    @Published private(set) var uptimeChecks: Int
    @Published private(set) var successfulUptimeChecks: Int
    @Published private(set) var metricSamples: [MetricSample] = []
    @Published private(set) var isLaunchingSSH = false
    @Published private(set) var sshLaunchErrorMessage: String?

    private var timer: Timer?
    private var sshConsecutiveFailures = 0
    private var coolifyConsecutiveFailures = 0
    // Use a stable suite so Debug, Release and future .app builds share settings.
    private let defaults = UserDefaults(suiteName: "com.vpsmonitor.app") ?? .standard

    var uptimePercent: Double {
        uptimeChecks > 0 ? Double(successfulUptimeChecks) / Double(uptimeChecks) * 100 : 0
    }

    var chartMetricSamples: [ChartMetricSample] {
        let now = Date()
        let dates = (0..<60).map { now.addingTimeInterval(Double($0 - 59) * 60) }
        let cpuValues = dates.map { date in nearestValue(to: date, keyPath: \.cpu) }
        let memoryValues = dates.map { date in nearestValue(to: date, keyPath: \.memory) }
        return dates.indices.compactMap { index in
            guard let cpu = interpolatedValue(in: cpuValues, at: index),
                  let memory = interpolatedValue(in: memoryValues, at: index) else { return nil }
            return ChartMetricSample(date: dates[index], cpu: cpu, memory: memory)
        }
    }

    var canOpenSSHSession: Bool {
        SSHSessionLauncher().isConfigured(configuration: configuration)
    }

    init() {
        configuration = ConfigurationStore(defaults: defaults).load()
        uptimeChecks = defaults.integer(forKey: "uptimeChecks")
        successfulUptimeChecks = defaults.integer(forKey: "successfulUptimeChecks")
        token = KeychainStore.read(account: "coolify-token")
        scheduleTimer()
        Task { await refresh() }
    }

    var overallState: HealthState {
        let configuredStates = [configuration.sshHost.isEmpty ? nil : sshAvailable,
                                configuration.coolifyURL.isEmpty ? nil : coolifyAvailable].compactMap { $0 }
        if sshConsecutiveFailures >= 2 || coolifyConsecutiveFailures >= 2 { return .critical }
        if projects.contains(where: { $0.health == .critical }) || (metrics?.diskPercent ?? 0) >= 90 { return .critical }
        if configuredStates.contains(false) { return .warning }
        if projects.contains(where: { $0.health == .warning }) ||
            (metrics?.cpuPercent ?? 0) >= 80 ||
            (metrics?.memoryPercent ?? 0) >= 80 ||
            (metrics?.diskPercent ?? 0) >= 80 { return .warning }
        return lastUpdated == nil ? .unknown : .healthy
    }

    func save() {
        configuration.refreshInterval = 60
        ConfigurationStore(defaults: defaults).save(configuration)
        do { try KeychainStore.save(token, account: "coolify-token"); errorMessage = nil }
        catch { errorMessage = "No se pudo guardar el token en Keychain: \(error.localizedDescription)" }
        scheduleTimer()
        Task { await refresh() }
    }

    func refresh() async {
        await refresh(isRetry: false)
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

    private func refresh(isRetry: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var errors: [String] = []

        if !configuration.sshHost.isEmpty {
            do {
                let newMetrics = try await SSHMetricsClient().fetch(configuration: configuration)
                metrics = newMetrics
                recordMetricSample(newMetrics)
                sshAvailable = true
                sshConsecutiveFailures = 0
                recordUptimeCheck(success: true)
            } catch {
                sshAvailable = false
                sshConsecutiveFailures += 1
                recordMetricSample(nil)
                recordUptimeCheck(success: false)
                errors.append(error.localizedDescription)
            }
        } else {
            sshAvailable = nil
        }
        if !configuration.coolifyURL.isEmpty {
            do {
                projects = try await CoolifyClient().fetchProjects(baseURL: configuration.coolifyURL, token: token)
                coolifyAvailable = true
                coolifyConsecutiveFailures = 0
            } catch {
                coolifyAvailable = false
                coolifyConsecutiveFailures += 1
                errors.append(error.localizedDescription)
            }
        } else {
            coolifyAvailable = nil
        }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.count < 2 { lastUpdated = Date() }
        if !errors.isEmpty && !isRetry {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.refresh(isRetry: true)
            }
        }
    }

    func quit() { NSApplication.shared.terminate(nil) }

    private func recordUptimeCheck(success: Bool) {
        uptimeChecks += 1
        if success { successfulUptimeChecks += 1 }
        defaults.set(uptimeChecks, forKey: "uptimeChecks")
        defaults.set(successfulUptimeChecks, forKey: "successfulUptimeChecks")
    }

    private func recordMetricSample(_ metrics: ServerMetrics?) {
        let now = Date()
        guard metricSamples.last.map({ now.timeIntervalSince($0.date) >= 60 }) ?? true else { return }
        metricSamples.append(MetricSample(date: now, cpu: metrics?.cpuPercent, memory: metrics?.memoryPercent))
        metricSamples = metricSamples.filter { now.timeIntervalSince($0.date) <= 3600 }.suffix(60).map { $0 }
    }

    private func nearestValue(to date: Date, keyPath: KeyPath<MetricSample, Double?>) -> Double? {
        let nearest = metricSamples
            .filter { abs($0.date.timeIntervalSince(date)) <= 30 }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        return nearest?[keyPath: keyPath]
    }

    private func interpolatedValue(in values: [Double?], at index: Int) -> Double? {
        if let value = values[index] { return value }
        let previous = values[..<index].reversed().compactMap { $0 }.first
        let next = values.dropFirst(index + 1).compactMap { $0 }.first
        switch (previous, next) {
        case let (before?, after?): return (before + after) / 2
        case let (before?, nil): return before
        case let (nil, after?): return after
        case (nil, nil): return nil
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
}
