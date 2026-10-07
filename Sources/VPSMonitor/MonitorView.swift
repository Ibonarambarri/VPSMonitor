import AppKit
import Charts
import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var model: MonitorViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.profiles.count > 1 {
                Divider()
                ServerOverview()
            }
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if model.isOffline {
                        Banner(symbol: "wifi.slash", color: .secondary, title: "Este Mac no tiene conexión",
                               detail: "Las comprobaciones se reanudarán al recuperar la red.")
                    }
                    if let monitor = model.selectedMonitor {
                        ServerDetail(monitor: monitor)
                    }
                    if let error = model.sshLaunchErrorMessage { ErrorBox(message: error) }
                    if let error = model.settingsError { ErrorBox(message: error) }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 420, height: model.profiles.count > 1 ? 680 : 620)
        .background(WindowVisibilityObserver { model.setPanelVisible($0) })
    }

    private var header: some View {
        let profile = model.selectedProfile
        let monitor = model.selectedMonitor
        return HStack(spacing: 10) {
            Image(systemName: "server.rack").font(.title2)
                .foregroundStyle(monitor?.overallState.color ?? .secondary)
            serverSwitcher(profile)
            Spacer(minLength: 4)
            if monitor?.isLive == true { LiveBadge() }
            Button(action: model.openSSHSession) {
                if model.isLaunchingSSH {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "terminal").font(.system(size: 14, weight: .semibold))
                }
            }
            .buttonStyle(InteractiveIconButtonStyle(size: 30, prominent: true))
            .disabled(!model.canOpenSSHSession || model.isLaunchingSSH)
            .help("Abrir SSH en \(profile.configuration.sshTerminal.displayName)")
            .accessibilityLabel("Abrir sesión SSH en \(profile.configuration.sshTerminal.displayName)")
            Button(action: model.refreshSelected) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(monitor?.isRefreshing == true ? .degrees(360) : .zero)
                    .animation(monitor?.isRefreshing == true ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: monitor?.isRefreshing == true)
            }
            .buttonStyle(InteractiveIconButtonStyle(size: 30))
            .help("Actualizar ahora")
            .accessibilityLabel("Actualizar ahora")
            Menu {
                if model.profiles.count > 1 {
                    Button("Actualizar todos los VPS ahora", action: model.refreshAll)
                }
                if let host = profile.configuration.sshHost.nonEmpty {
                    Button("Copiar host") { copy(host) }
                    Button("Copiar comando SSH") {
                        if let command = try? SSHCommandBuilder().build(configuration: profile.configuration) {
                            copy(command.warpShellCommand)
                        }
                    }
                }
                if let url = coolifyDashboardURL(profile) {
                    Button("Abrir Coolify") { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button("Ajustes…") { SettingsWindowController.shared.show(model: model) }
                Divider()
                Button("Salir de VPS Monitor", action: model.quit)
            } label: {
                MenuIconLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Más opciones")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder private func serverSwitcher(_ profile: VPSProfile) -> some View {
        let title = VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(profile.displayName).font(.headline).lineLimit(1)
                if model.profiles.count > 1 {
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Text(profile.configuration.sshHost.isEmpty ? "Sin configurar" : profile.configuration.sshHost)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if model.profiles.count > 1 {
            Menu {
                Section("Selecciona un VPS") {
                    ForEach(model.orderedMonitors) { monitor in
                        Button {
                            model.select(monitor.id)
                        } label: {
                            Label(monitor.profile.displayName + (monitor.id == model.selectedProfileID ? "  ✓" : ""),
                                  systemImage: monitor.overallState.symbol)
                        }
                    }
                }
                Divider()
                Button("Gestionar VPS…") { SettingsWindowController.shared.show(model: model) }
            } label: {
                title
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Cambiar de VPS")
        } else {
            title
        }
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                if let lastUpdated = model.selectedMonitor?.lastUpdated {
                    Text("Actualizado " + Formatters.relative(lastUpdated, now: context.date))
                } else {
                    Text("Sin datos todavía")
                }
                Spacer()
                if let monitor = model.selectedMonitor {
                    Text(monitor.isLive ? "En directo · cada \(Int(MonitorPreferences.liveRefreshInterval)) s"
                                        : "Cada " + Formatters.interval(monitor.currentInterval))
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
    }

    private func coolifyDashboardURL(_ profile: VPSProfile) -> URL? {
        guard let raw = profile.configuration.coolifyURL.nonEmpty,
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// One card per VPS so every server stays in view; clicking a card selects it.
private struct ServerOverview: View {
    @EnvironmentObject private var model: MonitorViewModel

    var body: some View {
        // Up to three servers share the width; more scroll sideways.
        if model.orderedMonitors.count <= 3 {
            cards(fill: true).padding(.horizontal, 14).padding(.vertical, 10)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                cards(fill: false).padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    private func cards(fill: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(model.orderedMonitors) { monitor in
                ServerOverviewCard(monitor: monitor, isSelected: monitor.id == model.selectedProfileID, fill: fill)
                    .onTapGesture { model.select(monitor.id) }
            }
        }
    }
}

private struct ServerOverviewCard: View {
    @ObservedObject var monitor: ServerMonitor
    let isSelected: Bool
    var fill = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(monitor.overallState.color).frame(width: 8, height: 8)
                Text(monitor.profile.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                if !monitor.alerts.isEmpty {
                    Text("\(monitor.alerts.count)").font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(monitor.overallState.color, in: Capsule())
                }
            }
            if let metrics = monitor.metrics {
                MiniBar(label: "CPU", value: metrics.cpuPercent, tint: .blue)
                MiniBar(label: "RAM", value: metrics.memoryPercent, tint: .purple)
            } else {
                Text(monitor.sshAvailable == false ? "Sin respuesta" : monitor.isConfigured ? "Conectando…" : "Sin configurar")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 30, alignment: .topLeading)
            }
        }
        .padding(9)
        .frame(minWidth: 120, maxWidth: fill ? .infinity : 150, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : isHovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct MiniBar: View {
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(value >= 90 ? .red : value >= 80 ? .orange : tint)
                        .frame(width: proxy.size.width * min(max(value / 100, 0), 1))
                }
            }
            .frame(height: 5)
            Text(Formatters.percent(value)).font(.system(size: 10, weight: .medium).monospacedDigit())
                .frame(width: 32, alignment: .trailing)
        }
    }
}

/// Everything about the selected VPS.
private struct ServerDetail: View {
    @EnvironmentObject private var model: MonitorViewModel
    @ObservedObject var monitor: ServerMonitor
    @State private var showAllContainers = false

    private var configuration: MonitorConfiguration { monitor.configuration }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(monitor.alerts) { alert in
                Banner(symbol: alert.severity.symbol, color: alert.severity.color, title: alert.title,
                       detail: alert.detail + " · desde " + alert.since.formatted(date: .omitted, time: .shortened))
            }
            metricsSection
            if let metrics = monitor.metrics {
                disksSection(metrics)
                processesSection(metrics)
                containersSection(metrics)
            }
            projectsSection
            ForEach(monitor.errorMessages, id: \.self) { ErrorBox(message: $0) }
        }
    }

    @ViewBuilder private var metricsSection: some View {
        HStack {
            SectionTitle("SERVIDOR")
            Spacer()
            Picker("Periodo", selection: $model.historyRange) {
                ForEach(HistoryRange.allCases) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 210)
        }
        if let metrics = monitor.metrics {
            let series = monitor.history.series(for: model.historyRange)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                HistoryMetricCard(title: "CPU", value: Formatters.percent(metrics.cpuPercent),
                                  series: series, range: model.historyRange,
                                  lines: [(\.cpu, .blue)], yDomain: 0...100,
                                  subtitle: cpuSubtitle(metrics))
                HistoryMetricCard(title: "RAM", value: Formatters.percent(metrics.memoryPercent),
                                  series: series, range: model.historyRange,
                                  lines: [(\.memory, .purple)], yDomain: 0...100,
                                  subtitle: memorySubtitle(metrics))
                HistoryMetricCard(title: "Red", value: "↓ " + Formatters.rate(metrics.networkReceiveRate),
                                  series: series, range: model.historyRange,
                                  lines: [(\.receiveRate, .teal), (\.transmitRate, .orange)], yDomain: nil,
                                  subtitle: "↑ " + Formatters.rate(metrics.networkTransmitRate))
                MetricCard(title: "Disponibilidad 24 h",
                           value: monitor.availability.map(Formatters.preciseAvailability) ?? "—",
                           subtitle: "Encendido " + Formatters.duration(metrics.uptimeSeconds),
                           progress: monitor.availability.map { $0 / 100 }, positiveProgress: true)
            }
            if metrics.rebootRequired {
                Label("El servidor necesita reiniciarse para aplicar actualizaciones.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: monitor.sshAvailable == false ? "bolt.horizontal.circle" : "waveform.path.ecg")
                    .font(.title).foregroundStyle(.secondary)
                Text(configuration.sshHost.isEmpty ? "Sin métricas" : monitor.sshAvailable == false ? "Sin respuesta" : "Esperando datos…")
                    .font(.headline)
                Text(configuration.sshHost.isEmpty ? "Configura el acceso SSH en Ajustes." : "Conectando con \(configuration.sshHost).")
                    .font(.caption).foregroundStyle(.secondary)
                if configuration.sshHost.isEmpty {
                    Button("Abrir Ajustes") { SettingsWindowController.shared.show(model: model) }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 130)
        }
    }

    @ViewBuilder private func disksSection(_ metrics: ServerMetrics) -> some View {
        if !metrics.disks.isEmpty {
            SectionTitle("DISCOS")
            Card {
                ForEach(metrics.disks) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(disk.mountPoint).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Formatters.bytes(disk.usedBytes) + " / " + Formatters.bytes(disk.totalBytes))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(Formatters.percent(disk.percent)).font(.callout.monospacedDigit().bold())
                                .frame(width: 44, alignment: .trailing)
                        }
                        ProgressView(value: min(disk.percent / 100, 1))
                            .tint(loadColor(disk.percent, threshold: model.preferences.diskAlertThreshold))
                    }
                    .help("\(disk.filesystem) · \(Formatters.bytes(disk.availableBytes)) libres")
                }
            }
        }
    }

    @ViewBuilder private func processesSection(_ metrics: ServerMetrics) -> some View {
        if !metrics.processes.isEmpty {
            SectionTitle("PROCESOS")
            Card {
                ForEach(metrics.processes) { process in
                    HStack(spacing: 8) {
                        Text(process.name).font(.callout).lineLimit(1)
                        Text(verbatim: String(process.pid)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        Spacer()
                        Text(Formatters.bytes(process.memoryBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(Formatters.percent(process.cpuPercent, digits: 1))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder private func containersSection(_ metrics: ServerMetrics) -> some View {
        if let containers = metrics.containers {
            let running = containers.filter { $0.state == "running" }.count
            let problems = containers.filter { $0.health == .critical || $0.health == .warning }
            let shown = showAllContainers ? containers.sorted { ($0.health.rank, $1.name) > ($1.health.rank, $0.name) } : problems
            HStack {
                SectionTitle("CONTENEDORES")
                Spacer()
                Text("\(running) de \(containers.count) en ejecución" + (problems.isEmpty ? "" : " · \(problems.count) con incidencias"))
                    .font(.caption).foregroundStyle(problems.isEmpty ? Color.secondary : Color.orange)
            }
            if !shown.isEmpty || !metrics.failedUnits.isEmpty || !containers.isEmpty {
                Card {
                    ForEach(shown) { container in
                        HStack(spacing: 8) {
                            Circle().fill(container.health.color).frame(width: 7, height: 7)
                            Text(container.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(container.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    ForEach(metrics.failedUnits, id: \.self) { unit in FailedUnitRow(unit: unit) }
                    if !containers.isEmpty {
                        Button(showAllContainers ? "Mostrar solo incidencias" : "Ver los \(containers.count) contenedores") {
                            withAnimation(.easeOut(duration: 0.15)) { showAllContainers.toggle() }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
        } else if !metrics.failedUnits.isEmpty {
            SectionTitle("SERVICIOS")
            Card {
                ForEach(metrics.failedUnits, id: \.self) { unit in FailedUnitRow(unit: unit) }
            }
        }
    }

    @ViewBuilder private var projectsSection: some View {
        if !configuration.coolifyURL.isEmpty || !monitor.projects.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle("PROYECTOS")
                    Spacer()
                    let resources = monitor.projects.flatMap(\.resources)
                    let failing = resources.filter { $0.health == .critical }.count
                    Text("\(monitor.projects.count) proyectos · \(resources.count) recursos" + (failing > 0 ? " · \(failing) caídos" : ""))
                        .font(.caption).foregroundStyle(failing > 0 ? Color.red : Color.secondary)
                }
                if monitor.projects.isEmpty {
                    // A failed check is reported in the error box below instead.
                    if monitor.coolifyAvailable != false {
                        Text(monitor.coolifyAvailable == nil ? "Consultando Coolify…" : "Sin proyectos en Coolify.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                } else {
                    ForEach(monitor.projects) { project in ProjectDisclosure(project: project) }
                }
            }
        }
    }

    private func cpuSubtitle(_ metrics: ServerMetrics) -> String {
        if metrics.stealPercent >= 5 { return "steal " + Formatters.percent(metrics.stealPercent) + " · iowait " + Formatters.percent(metrics.iowaitPercent) }
        if metrics.iowaitPercent >= 5 { return "iowait " + Formatters.percent(metrics.iowaitPercent) }
        let load = metrics.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " ")
        return metrics.cores > 0 ? "carga \(load) · \(metrics.cores) núcleos" : "carga \(load)"
    }

    private func memorySubtitle(_ metrics: ServerMetrics) -> String {
        let memory = Formatters.bytes(metrics.usedMemoryBytes) + " / " + Formatters.bytes(metrics.totalMemoryBytes)
        guard metrics.totalSwapBytes > 0, metrics.usedSwapBytes > 0 else { return memory }
        return memory + " · swap " + Formatters.percent(metrics.swapPercent)
    }

    private func loadColor(_ percent: Double, threshold: Double) -> Color {
        percent >= threshold ? .red : percent >= threshold - 10 ? .orange : .accentColor
    }
}

private struct FailedUnitRow: View {
    let unit: String

    var body: some View {
        let benign = AlertEngine.isBenign(unit: unit)
        HStack(spacing: 8) {
            Circle().fill(benign ? Color.secondary.opacity(0.5) : .orange).frame(width: 7, height: 7)
            Text(unit).font(.callout).lineLimit(1).foregroundStyle(benign ? .secondary : .primary)
            Spacer()
            Text(benign ? "fallo de arranque inocuo" : "systemd · failed").font(.caption).foregroundStyle(.secondary)
        }
        .help(benign ? "Este servicio suele fallar en el arranque de un VPS sin consecuencias; no genera alertas." : "Servicio systemd en estado failed.")
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).font(.caption.bold()).foregroundStyle(.secondary) }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Banner: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ErrorBox: View {
    let message: String

    var body: some View {
        Label { Text(message).font(.caption).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ProjectDisclosure: View {
    let project: CoolifyProject
    @State private var isExpanded: Bool

    init(project: CoolifyProject) {
        self.project = project
        // Projects with problems open by default so failures are visible at a glance.
        _isExpanded = State(initialValue: project.health == .critical || project.health == .warning)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(project.health.color).frame(width: 8, height: 8)
                    Text(project.name).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.leading, 10)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(project.environments) { environment in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(environment.name.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
                            if environment.resources.isEmpty { Text("Sin recursos").font(.caption).foregroundStyle(.secondary) }
                            ForEach(environment.resources) { resource in
                                HStack {
                                    Circle().fill(resource.health.color).frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(resource.name).font(.callout).lineLimit(1)
                                        Text(resource.type).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Text(resource.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if let url = resource.url {
                                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                                            .buttonStyle(InteractiveIconButtonStyle(size: 26))
                                            .help("Abrir \(url.host ?? "recurso")")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .transition(.opacity)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private var summary: String {
        let bad = project.resources.filter { $0.health == .critical }.count
        return bad > 0 ? "\(bad) con problemas" : "\(project.resources.count) recursos"
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum Formatters {
    static func percent(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits))) + "%"
    }

    static func preciseAvailability(_ value: Double) -> String {
        percent(value, digits: value >= 99.95 || value < 90 ? 0 : 2)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .decimal) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "—"
    }

    static func interval(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "\(Int(seconds / 60)) min" : "\(Int(seconds)) s"
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 5 { return "ahora" }
        if seconds < 60 { return "hace \(seconds) s" }
        if seconds < 3600 { return "hace \(seconds / 60) min" }
        return "a las " + date.formatted(date: .omitted, time: .shortened)
    }
}

private struct LiveBadge: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.red).frame(width: 6, height: 6).opacity(pulse ? 0.35 : 1)
            Text("EN DIRECTO").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Actualización en directo")
    }
}

/// Reports whether the menu bar panel is on screen, so the app can poll faster while it is.
private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastValue: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { report(false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    let closing = notification.name == NSWindow.willCloseNotification
                    self?.evaluate(forceHidden: closing)
                })
            }
            evaluate(forceHidden: false)
        }

        private func evaluate(forceHidden: Bool) {
            guard let window, !forceHidden else { report(false); return }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard visible != lastValue else { return }
            lastValue = visible
            // Defer so SwiftUI state does not change during a view update.
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

private struct MetricCard: View {
    let title: String, value: String
    var subtitle: String? = nil
    var progress: Double? = nil
    var positiveProgress = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.65)
            Spacer(minLength: 0)
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(positiveProgress ? (progress >= 0.99 ? .green : progress >= 0.95 ? .orange : .red) : (progress >= 0.9 ? .red : progress >= 0.8 ? .orange : .accentColor))
            }
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7) }
        }.padding(10).frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct HistoryMetricCard: View {
    let title: String
    let value: String
    let series: ChartSeries
    let range: HistoryRange
    let lines: [(KeyPath<ChartPoint, Double?>, Color)]
    let yDomain: ClosedRange<Double>?
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(.body, design: .rounded).bold().monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            chart.frame(height: 46)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var chart: some View {
        let now = Date()
        return Chart {
            ForEach(series.outages, id: \.self) { date in
                RuleMark(x: .value("Hora", date))
                    .foregroundStyle(.red.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                // Samples from older versions have no network data; leave those stretches empty.
                ForEach(series.points.filter { $0[keyPath: line.0] != nil }) { point in
                    let value = point[keyPath: line.0] ?? 0
                    if lines.count == 1 {
                        AreaMark(x: .value("Hora", point.date), y: .value("Uso", value),
                                 series: .value("Tramo", "\(index)-\(point.segment)"))
                            .foregroundStyle(LinearGradient(colors: [line.1.opacity(0.28), line.1.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                    }
                    LineMark(x: .value("Hora", point.date), y: .value("Uso", value),
                             series: .value("Tramo", "\(index)-\(point.segment)"))
                        .foregroundStyle(line.1)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-range.duration)...now)
        .modifier(OptionalYDomain(domain: yDomain))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

private struct OptionalYDomain: ViewModifier {
    let domain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain { content.chartYScale(domain: domain) } else { content }
    }
}

private struct InteractiveIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        InteractiveIconButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            size: size,
            prominent: prominent
        )
    }
}

private struct InteractiveIconButtonBody<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    let label: Label
    let isPressed: Bool
    let size: CGFloat
    let prominent: Bool

    var body: some View {
        label
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 1)
            }
            .scaleEffect(isPressed ? 0.92 : 1)
            .shadow(color: prominent && isEnabled ? .black.opacity(0.08) : .clear, radius: 2, y: 1)
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var backgroundColor: Color {
        if isPressed { return .accentColor.opacity(0.25) }
        if isHovering { return prominent ? .accentColor.opacity(0.19) : .primary.opacity(0.1) }
        return prominent ? .accentColor.opacity(0.12) : .primary.opacity(0.045)
    }

    private var borderColor: Color {
        if isPressed || isHovering { return .accentColor.opacity(0.4) }
        return prominent ? .accentColor.opacity(0.25) : .primary.opacity(0.08)
    }
}

private struct MenuIconLabel: View {
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .frame(width: 30, height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(isHovering ? Color.primary.opacity(0.1) : .primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovering ? Color.accentColor.opacity(0.4) : .primary.opacity(0.08), lineWidth: 1)
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
