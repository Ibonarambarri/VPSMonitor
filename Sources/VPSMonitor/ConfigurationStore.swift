import Foundation

struct ConfigurationStore {
    let defaults: UserDefaults

    func load() -> MonitorConfiguration {
        let fallback = MonitorConfiguration()
        let interval = defaults.object(forKey: "refreshInterval") as? Double ?? fallback.refreshInterval
        return MonitorConfiguration(
            coolifyURL: defaults.string(forKey: "coolifyURL") ?? "",
            sshHost: defaults.string(forKey: "sshHost") ?? "",
            sshUser: defaults.string(forKey: "sshUser") ?? fallback.sshUser,
            sshPort: defaults.string(forKey: "sshPort") ?? fallback.sshPort,
            sshKeyPath: defaults.string(forKey: "sshKeyPath") ?? fallback.sshKeyPath,
            refreshInterval: MonitorConfiguration.refreshIntervals.contains(interval) ? interval : fallback.refreshInterval,
            sshTerminal: SSHTerminal(rawValue: defaults.string(forKey: "sshTerminal") ?? "") ?? .appleTerminal,
            customTerminalExecutable: defaults.string(forKey: "customTerminalExecutable") ?? "",
            customTerminalArguments: defaults.string(forKey: "customTerminalArguments") ?? "",
            liveWhileOpen: bool("liveWhileOpen", fallback.liveWhileOpen),
            notificationsEnabled: bool("notificationsEnabled", fallback.notificationsEnabled),
            showCPUInMenuBar: bool("showCPUInMenuBar", fallback.showCPUInMenuBar),
            cpuAlertThreshold: threshold("cpuAlertThreshold", fallback.cpuAlertThreshold),
            memoryAlertThreshold: threshold("memoryAlertThreshold", fallback.memoryAlertThreshold),
            diskAlertThreshold: threshold("diskAlertThreshold", fallback.diskAlertThreshold)
        )
    }

    func save(_ configuration: MonitorConfiguration) {
        defaults.set(configuration.coolifyURL, forKey: "coolifyURL")
        defaults.set(configuration.sshHost, forKey: "sshHost")
        defaults.set(configuration.sshUser, forKey: "sshUser")
        defaults.set(configuration.sshPort, forKey: "sshPort")
        defaults.set(configuration.sshKeyPath, forKey: "sshKeyPath")
        defaults.set(configuration.refreshInterval, forKey: "refreshInterval")
        defaults.set(configuration.sshTerminal.rawValue, forKey: "sshTerminal")
        defaults.set(configuration.customTerminalExecutable, forKey: "customTerminalExecutable")
        defaults.set(configuration.customTerminalArguments, forKey: "customTerminalArguments")
        defaults.set(configuration.liveWhileOpen, forKey: "liveWhileOpen")
        defaults.set(configuration.notificationsEnabled, forKey: "notificationsEnabled")
        defaults.set(configuration.showCPUInMenuBar, forKey: "showCPUInMenuBar")
        defaults.set(configuration.cpuAlertThreshold, forKey: "cpuAlertThreshold")
        defaults.set(configuration.memoryAlertThreshold, forKey: "memoryAlertThreshold")
        defaults.set(configuration.diskAlertThreshold, forKey: "diskAlertThreshold")
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func threshold(_ key: String, _ fallback: Double) -> Double {
        guard let value = defaults.object(forKey: key) as? Double, (50...100).contains(value) else { return fallback }
        return value
    }
}
