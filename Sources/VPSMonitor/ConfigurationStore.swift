import Foundation

/// Reads and writes the VPS list and the shared preferences. The keys are the ones
/// used by versions 1.1 and 1.2, so existing installations keep their settings.
struct ConfigurationStore {
    let defaults: UserDefaults

    private static let profilesKey = "vpsProfiles"
    private static let selectedProfileKey = "selectedVPSProfileID"

    // MARK: VPS profiles

    func loadProfiles() -> [VPSProfile] {
        if let data = defaults.data(forKey: Self.profilesKey),
           let profiles = try? JSONDecoder().decode([VPSProfile].self, from: data),
           !profiles.isEmpty {
            return profiles
        }
        return [legacyProfile()]
    }

    func saveProfiles(_ profiles: [VPSProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }

    func loadSelectedProfileID() -> UUID? {
        defaults.string(forKey: Self.selectedProfileKey).flatMap(UUID.init(uuidString:))
    }

    func saveSelectedProfileID(_ id: UUID) {
        defaults.set(id.uuidString, forKey: Self.selectedProfileKey)
    }

    /// Version 1.1 stored a single server directly under top-level keys.
    func legacyProfile() -> VPSProfile {
        let fallback = MonitorConfiguration()
        let configuration = MonitorConfiguration(
            coolifyURL: defaults.string(forKey: "coolifyURL") ?? "",
            sshHost: defaults.string(forKey: "sshHost") ?? "",
            sshUser: defaults.string(forKey: "sshUser") ?? fallback.sshUser,
            sshPort: defaults.string(forKey: "sshPort") ?? fallback.sshPort,
            sshKeyPath: defaults.string(forKey: "sshKeyPath") ?? fallback.sshKeyPath,
            sshTerminal: SSHTerminal(rawValue: defaults.string(forKey: "sshTerminal") ?? "") ?? .appleTerminal,
            customTerminalExecutable: defaults.string(forKey: "customTerminalExecutable") ?? "",
            customTerminalArguments: defaults.string(forKey: "customTerminalArguments") ?? ""
        )
        return VPSProfile(id: Self.legacyProfileID, name: "Mi VPS", configuration: configuration)
    }

    /// Fixed so the migrated server keeps its history between launches until it is saved.
    static let legacyProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: Shared preferences

    func loadPreferences() -> MonitorPreferences {
        let fallback = MonitorPreferences()
        let interval = defaults.object(forKey: "refreshInterval") as? Double ?? fallback.refreshInterval
        return MonitorPreferences(
            refreshInterval: MonitorPreferences.refreshIntervals.contains(interval) ? interval : fallback.refreshInterval,
            liveWhileOpen: bool("liveWhileOpen", fallback.liveWhileOpen),
            notificationsEnabled: bool("notificationsEnabled", fallback.notificationsEnabled),
            showCPUInMenuBar: bool("showCPUInMenuBar", fallback.showCPUInMenuBar),
            cpuAlertThreshold: threshold("cpuAlertThreshold", fallback.cpuAlertThreshold),
            memoryAlertThreshold: threshold("memoryAlertThreshold", fallback.memoryAlertThreshold),
            diskAlertThreshold: threshold("diskAlertThreshold", fallback.diskAlertThreshold)
        )
    }

    func savePreferences(_ preferences: MonitorPreferences) {
        defaults.set(preferences.refreshInterval, forKey: "refreshInterval")
        defaults.set(preferences.liveWhileOpen, forKey: "liveWhileOpen")
        defaults.set(preferences.notificationsEnabled, forKey: "notificationsEnabled")
        defaults.set(preferences.showCPUInMenuBar, forKey: "showCPUInMenuBar")
        defaults.set(preferences.cpuAlertThreshold, forKey: "cpuAlertThreshold")
        defaults.set(preferences.memoryAlertThreshold, forKey: "memoryAlertThreshold")
        defaults.set(preferences.diskAlertThreshold, forKey: "diskAlertThreshold")
    }

    // MARK: Version 1.2 history

    /// Version 1.2 kept the last hour of CPU and RAM per VPS in preferences.
    func legacySamples(for id: UUID) -> [MetricSample] {
        struct LegacySample: Decodable { let date: Date; let cpu: Double?; let memory: Double? }
        guard let data = defaults.data(forKey: "metricSamples.\(id.uuidString.lowercased())"),
              let samples = try? JSONDecoder().decode([LegacySample].self, from: data) else { return [] }
        return samples.map { MetricSample(date: $0.date, cpu: $0.cpu, memory: $0.cpu == nil ? nil : $0.memory) }
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func threshold(_ key: String, _ fallback: Double) -> Double {
        guard let value = defaults.object(forKey: key) as? Double, (50...100).contains(value) else { return fallback }
        return value
    }
}
