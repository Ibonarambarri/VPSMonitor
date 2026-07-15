import Foundation

struct ConfigurationStore {
    let defaults: UserDefaults

    func load() -> MonitorConfiguration {
        MonitorConfiguration(
            coolifyURL: defaults.string(forKey: "coolifyURL") ?? "",
            sshHost: defaults.string(forKey: "sshHost") ?? "",
            sshUser: defaults.string(forKey: "sshUser") ?? "root",
            sshPort: defaults.string(forKey: "sshPort") ?? "22",
            sshKeyPath: defaults.string(forKey: "sshKeyPath") ?? "~/.ssh/id_ed25519",
            refreshInterval: 60,
            sshTerminal: SSHTerminal(rawValue: defaults.string(forKey: "sshTerminal") ?? "") ?? .appleTerminal,
            customTerminalExecutable: defaults.string(forKey: "customTerminalExecutable") ?? "",
            customTerminalArguments: defaults.string(forKey: "customTerminalArguments") ?? ""
        )
    }

    func save(_ configuration: MonitorConfiguration) {
        defaults.set(configuration.coolifyURL, forKey: "coolifyURL")
        defaults.set(configuration.sshHost, forKey: "sshHost")
        defaults.set(configuration.sshUser, forKey: "sshUser")
        defaults.set(configuration.sshPort, forKey: "sshPort")
        defaults.set(configuration.sshKeyPath, forKey: "sshKeyPath")
        defaults.set(60.0, forKey: "refreshInterval")
        defaults.set(configuration.sshTerminal.rawValue, forKey: "sshTerminal")
        defaults.set(configuration.customTerminalExecutable, forKey: "customTerminalExecutable")
        defaults.set(configuration.customTerminalArguments, forKey: "customTerminalArguments")
    }
}
