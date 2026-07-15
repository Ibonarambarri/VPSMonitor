import Foundation
import SwiftUI

enum SSHTerminal: String, CaseIterable, Identifiable {
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

struct ServerMetrics: Equatable {
    var cpuPercent = 0.0
    var usedMemoryBytes: Int64 = 0
    var totalMemoryBytes: Int64 = 0
    var usedDiskBytes: Int64 = 0
    var totalDiskBytes: Int64 = 0
    var load = "—"
    var uptime = "—"

    var memoryPercent: Double { totalMemoryBytes > 0 ? Double(usedMemoryBytes) / Double(totalMemoryBytes) * 100 : 0 }
    var diskPercent: Double { totalDiskBytes > 0 ? Double(usedDiskBytes) / Double(totalDiskBytes) * 100 : 0 }
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

struct MonitorConfiguration: Equatable {
    var coolifyURL = ""
    var sshHost = ""
    var sshUser = "root"
    var sshPort = "22"
    var sshKeyPath = "~/.ssh/id_ed25519"
    var refreshInterval = 30.0
    var sshTerminal: SSHTerminal = .appleTerminal
    var customTerminalExecutable = ""
    var customTerminalArguments = ""
}
