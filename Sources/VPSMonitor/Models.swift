import Foundation
import SwiftUI

enum SSHTerminal: String, CaseIterable, Identifiable, Codable {
    case appleTerminal
    case warp
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleTerminal: "Terminal de Apple"
        case .warp: "Warp"
        case .custom: "Personalizada"
        }
    }
}

enum HealthState: String, Codable {
    case healthy, warning, critical, unknown

    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.circle.fill"
        case .unknown: "server.rack"
        }
    }

    var accessibilityName: String {
        switch self {
        case .healthy: "todo correcto"
        case .warning: "incidencia parcial"
        case .critical: "problema crítico"
        case .unknown: "estado desconocido"
        }
    }
}

struct DiskUsage: Equatable, Identifiable {
    let filesystem: String
    let mountPoint: String
    let usedBytes: Int64
    let availableBytes: Int64
    let totalBytes: Int64

    var id: String { mountPoint }
    /// Matches `df`: reserved blocks are not counted as available space.
    var percent: Double { usedBytes + availableBytes > 0 ? Double(usedBytes) / Double(usedBytes + availableBytes) * 100 : 0 }
}

struct ProcessUsage: Equatable, Identifiable {
    let pid: Int
    let name: String
    let cpuPercent: Double
    let memoryBytes: Int64

    var id: Int { pid }
}

struct ContainerStatus: Equatable, Identifiable {
    let name: String
    let state: String
    let status: String

    var id: String { name }

    var health: HealthState {
        let state = state.lowercased(), status = status.lowercased()
        if state == "restarting" || state == "dead" || status.contains("(unhealthy)") { return .critical }
        if state == "running" { return status.contains("health: starting") ? .warning : .healthy }
        if state == "paused" { return .warning }
        if state == "exited" { return status.hasPrefix("exited (0)") ? .unknown : .warning }
        return .unknown
    }
}

struct ServerMetrics: Equatable {
    var cpuPercent = 0.0
    var iowaitPercent = 0.0
    var stealPercent = 0.0
    var cores = 0
    var usedMemoryBytes: Int64 = 0
    var totalMemoryBytes: Int64 = 0
    var usedSwapBytes: Int64 = 0
    var totalSwapBytes: Int64 = 0
    var disks: [DiskUsage] = []
    var load: [Double] = []
    var uptimeSeconds: TimeInterval = 0
    /// Bytes per second across physical interfaces.
    var networkReceiveRate = 0.0
    var networkTransmitRate = 0.0
    var processes: [ProcessUsage] = []
    /// `nil` when Docker is not installed or the SSH user cannot query it.
    var containers: [ContainerStatus]?
    var failedUnits: [String] = []
    var rebootRequired = false

    var memoryPercent: Double { totalMemoryBytes > 0 ? Double(usedMemoryBytes) / Double(totalMemoryBytes) * 100 : 0 }
    var swapPercent: Double { totalSwapBytes > 0 ? Double(usedSwapBytes) / Double(totalSwapBytes) * 100 : 0 }
    var rootDisk: DiskUsage? { disks.first { $0.mountPoint == "/" } ?? disks.first }
    var fullestDisk: DiskUsage? { disks.max { $0.percent < $1.percent } }
}

struct CoolifyResource: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let status: String
    let url: URL?

    var health: HealthState {
        let value = status.lowercased()
        if value.contains("stop") || value.contains("exit") || value.contains("fail") || value.contains("unhealthy") { return .critical }
        if value.contains("degraded") || value.contains("starting") || value.contains("restart") { return .warning }
        if value.contains("running") || value.contains("healthy") { return .healthy }
        return .unknown
    }
}

struct CoolifyEnvironment: Identifiable, Equatable {
    let id: String
    let name: String
    let resources: [CoolifyResource]
}

struct CoolifyProject: Identifiable, Equatable {
    let id: String
    let name: String
    let environments: [CoolifyEnvironment]

    var resources: [CoolifyResource] { environments.flatMap(\.resources) }
    var health: HealthState {
        if resources.contains(where: { $0.health == .critical }) { return .critical }
        if resources.contains(where: { $0.health == .warning }) { return .warning }
        if !resources.isEmpty && resources.allSatisfy({ $0.health == .healthy }) { return .healthy }
        return .unknown
    }
}

/// Connection settings for one VPS. The JSON keys match version 1.2, so settings
/// survive both upgrades and downgrades.
struct MonitorConfiguration: Equatable, Codable {
    var coolifyURL = ""
    var sshHost = ""
    var sshUser = "root"
    var sshPort = "22"
    var sshKeyPath = "~/.ssh/id_ed25519"
    var sshTerminal: SSHTerminal = .appleTerminal
    var customTerminalExecutable = ""
    var customTerminalArguments = ""

    init(coolifyURL: String = "", sshHost: String = "", sshUser: String = "root", sshPort: String = "22",
         sshKeyPath: String = "~/.ssh/id_ed25519", sshTerminal: SSHTerminal = .appleTerminal,
         customTerminalExecutable: String = "", customTerminalArguments: String = "") {
        self.coolifyURL = coolifyURL
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.sshKeyPath = sshKeyPath
        self.sshTerminal = sshTerminal
        self.customTerminalExecutable = customTerminalExecutable
        self.customTerminalArguments = customTerminalArguments
    }

    private enum CodingKeys: String, CodingKey {
        case coolifyURL, sshHost, sshUser, sshPort, sshKeyPath, sshTerminal
        case customTerminalExecutable, customTerminalArguments, refreshInterval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MonitorConfiguration()
        coolifyURL = try container.decodeIfPresent(String.self, forKey: .coolifyURL) ?? fallback.coolifyURL
        sshHost = try container.decodeIfPresent(String.self, forKey: .sshHost) ?? fallback.sshHost
        sshUser = try container.decodeIfPresent(String.self, forKey: .sshUser) ?? fallback.sshUser
        sshPort = try container.decodeIfPresent(String.self, forKey: .sshPort) ?? fallback.sshPort
        sshKeyPath = try container.decodeIfPresent(String.self, forKey: .sshKeyPath) ?? fallback.sshKeyPath
        sshTerminal = (try? container.decodeIfPresent(SSHTerminal.self, forKey: .sshTerminal)) ?? fallback.sshTerminal
        customTerminalExecutable = try container.decodeIfPresent(String.self, forKey: .customTerminalExecutable) ?? ""
        customTerminalArguments = try container.decodeIfPresent(String.self, forKey: .customTerminalArguments) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coolifyURL, forKey: .coolifyURL)
        try container.encode(sshHost, forKey: .sshHost)
        try container.encode(sshUser, forKey: .sshUser)
        try container.encode(sshPort, forKey: .sshPort)
        try container.encode(sshKeyPath, forKey: .sshKeyPath)
        try container.encode(sshTerminal, forKey: .sshTerminal)
        try container.encode(customTerminalExecutable, forKey: .customTerminalExecutable)
        try container.encode(customTerminalArguments, forKey: .customTerminalArguments)
        // Version 1.2 requires this key; the interval is now a global preference.
        try container.encode(60.0, forKey: .refreshInterval)
    }
}

struct VPSProfile: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var configuration: MonitorConfiguration

    init(id: UUID = UUID(), name: String, configuration: MonitorConfiguration = MonitorConfiguration()) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return configuration.sshHost.isEmpty ? "VPS sin nombre" : configuration.sshHost
    }
}

/// Settings shared by every VPS.
struct MonitorPreferences: Equatable {
    static let refreshIntervals: [Double] = [10, 30, 60, 300]
    static let liveRefreshInterval = 2.0

    var refreshInterval = 30.0
    /// Poll every couple of seconds while the panel is open.
    var liveWhileOpen = true
    var notificationsEnabled = true
    var showCPUInMenuBar = false
    var cpuAlertThreshold = 90.0
    var memoryAlertThreshold = 90.0
    var diskAlertThreshold = 85.0
}
