import Foundation
import UserNotifications

struct MonitorAlert: Identifiable, Equatable {
    let id: String
    let severity: HealthState
    let title: String
    let detail: String
    let since: Date
}

struct AlertNotification: Equatable {
    let id: String
    let title: String
    let body: String
}

/// What the alert rules look at after each check.
struct AlertSnapshot {
    var thresholds = (cpu: 90.0, memory: 90.0, disk: 85.0)
    /// `nil` when SSH is not configured.
    var sshFailures: Int?
    var sshError: String?
    /// `nil` when the last SSH check failed; metric alerts then keep their previous state.
    var metrics: ServerMetrics?
    /// `nil` when Coolify is not configured.
    var coolifyFailures: Int?
    /// `nil` when the last Coolify check failed; resource alerts then keep their previous state.
    var projects: [CoolifyProject]?
}

/// Turns raw checks into alerts with hysteresis: load-based conditions must last a few
/// minutes before they fire, and clear only once the value falls clearly below the threshold.
struct AlertEngine {
    static let sustainedLoadDuration: TimeInterval = 3 * 60
    static let sustainedStealDuration: TimeInterval = 5 * 60
    static let failuresBeforeDown = 2
    static let hysteresis = 5.0
    /// Boot-time units that commonly fail on VPS images without affecting the server.
    static let benignUnits: Set<String> = [
        "systemd-networkd-wait-online.service", "NetworkManager-wait-online.service",
        "cloud-init.service", "cloud-init-local.service", "cloud-config.service", "cloud-final.service"
    ]

    static func isBenign(unit: String) -> Bool { benignUnits.contains(unit) }

    private(set) var active: [String: MonitorAlert] = [:]
    private var pendingSince: [String: Date] = [:]

    var activeAlerts: [MonitorAlert] {
        active.values.sorted {
            ($0.severity.rank, $1.since) > ($1.severity.rank, $0.since)
        }
    }

    var overallSeverity: HealthState? { activeAlerts.first?.severity }

    mutating func reset() {
        active = [:]
        pendingSince = [:]
    }

    /// Returns the notifications to send for alerts that started or ended.
    mutating func evaluate(_ snapshot: AlertSnapshot, now: Date = Date()) -> [AlertNotification] {
        var candidates: [String: Candidate] = [:]
        var retainedPrefixes: [String] = []

        if let failures = snapshot.sshFailures {
            if failures >= Self.failuresBeforeDown {
                candidates["ssh.down"] = Candidate(severity: .critical, title: "Servidor sin respuesta",
                                                   detail: snapshot.sshError ?? "Las comprobaciones SSH fallan.")
            }
            if let metrics = snapshot.metrics {
                addMetricCandidates(metrics, thresholds: snapshot.thresholds, to: &candidates)
            } else {
                retainedPrefixes.append("metric.")
            }
        }

        if let failures = snapshot.coolifyFailures {
            if failures >= Self.failuresBeforeDown {
                candidates["coolify.down"] = Candidate(severity: .warning, title: "Coolify no responde",
                                                       detail: "No se pudo consultar la API de Coolify.")
            }
            if let projects = snapshot.projects {
                for project in projects {
                    for resource in project.resources where resource.health == .critical {
                        candidates["coolify.resource.\(resource.id)"] = Candidate(
                            severity: .critical, title: "\(resource.name) con problemas",
                            detail: "\(project.name) · \(resource.status)")
                    }
                }
            } else {
                retainedPrefixes.append("coolify.resource.")
            }
        }

        pendingSince = pendingSince.filter { candidates[$0.key] != nil }
        var nextActive: [String: MonitorAlert] = [:]
        for (key, candidate) in candidates {
            if let existing = active[key] {
                nextActive[key] = MonitorAlert(id: key, severity: candidate.severity, title: candidate.title,
                                               detail: candidate.detail, since: existing.since)
                continue
            }
            let since = pendingSince[key] ?? now
            pendingSince[key] = since
            if now.timeIntervalSince(since) >= candidate.sustain {
                nextActive[key] = MonitorAlert(id: key, severity: candidate.severity, title: candidate.title,
                                               detail: candidate.detail, since: since)
                pendingSince[key] = nil
            }
        }
        for (key, alert) in active where nextActive[key] == nil && retainedPrefixes.contains(where: key.hasPrefix) {
            nextActive[key] = alert
        }

        var notifications: [AlertNotification] = []
        for (key, alert) in nextActive.sorted(by: { $0.key < $1.key }) where active[key] == nil {
            notifications.append(AlertNotification(id: key, title: alert.title, body: alert.detail))
        }
        for (key, alert) in active.sorted(by: { $0.key < $1.key }) where nextActive[key] == nil {
            notifications.append(AlertNotification(id: key, title: "Resuelto: \(alert.title)", body: "Vuelve a la normalidad."))
        }
        active = nextActive
        return notifications
    }

    private func addMetricCandidates(_ metrics: ServerMetrics, thresholds: (cpu: Double, memory: Double, disk: Double),
                                     to candidates: inout [String: Candidate]) {
        if exceeds(metrics.cpuPercent, thresholds.cpu, key: "metric.cpu") {
            candidates["metric.cpu"] = Candidate(severity: .warning, title: "CPU alta",
                                                 detail: "\(Self.percent(metrics.cpuPercent)) de uso sostenido.",
                                                 sustain: Self.sustainedLoadDuration)
        }
        if exceeds(metrics.memoryPercent, thresholds.memory, key: "metric.memory") {
            candidates["metric.memory"] = Candidate(severity: .warning, title: "Memoria alta",
                                                    detail: "\(Self.percent(metrics.memoryPercent)) de RAM en uso.",
                                                    sustain: Self.sustainedLoadDuration)
        }
        if exceeds(metrics.stealPercent, 20, key: "metric.steal") {
            candidates["metric.steal"] = Candidate(severity: .warning, title: "CPU robada por el proveedor",
                                                   detail: "Steal del \(Self.percent(metrics.stealPercent)): el host del VPS está saturado.",
                                                   sustain: Self.sustainedStealDuration)
        }
        for disk in metrics.disks {
            let key = "metric.disk.\(disk.mountPoint)"
            if exceeds(disk.percent, thresholds.disk, key: key) {
                candidates[key] = Candidate(severity: disk.percent >= 95 ? .critical : .warning,
                                            title: "Disco \(disk.mountPoint) casi lleno",
                                            detail: "\(Self.percent(disk.percent)) ocupado.")
            }
        }
        let failedUnits = metrics.failedUnits.filter { !Self.isBenign(unit: $0) }
        if !failedUnits.isEmpty {
            candidates["metric.units"] = Candidate(severity: .warning, title: "Servicios systemd fallidos",
                                                   detail: failedUnits.joined(separator: ", "))
        }
        for container in metrics.containers ?? [] where container.health == .critical {
            candidates["metric.container.\(container.name)"] = Candidate(
                severity: .critical, title: "Contenedor \(container.name)", detail: container.status)
        }
    }

    private func exceeds(_ value: Double, _ threshold: Double, key: String) -> Bool {
        value >= (active[key] == nil ? threshold : threshold - Self.hysteresis)
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + " %"
    }

    private struct Candidate {
        let severity: HealthState
        let title: String
        let detail: String
        var sustain: TimeInterval = 0
    }
}

extension HealthState {
    var rank: Int {
        switch self {
        case .critical: 3
        case .warning: 2
        case .healthy: 1
        case .unknown: 0
        }
    }
}

enum AlertNotifier {
    /// Notifications need a bundle identifier, so they are disabled under `swift run`.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ notification: AlertNotification) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = "vpsmonitor"
        let request = UNNotificationRequest(identifier: "\(notification.id).\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Shows banners even while the panel is open.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func install() {
        guard AlertNotifier.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
