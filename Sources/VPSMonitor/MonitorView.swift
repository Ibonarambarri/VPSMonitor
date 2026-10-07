import Charts
import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var model: MonitorViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: false) { content }
            Divider()
            footer
        }
        .frame(width: 400, height: 620)
        .background(WindowVisibilityObserver { model.setPanelVisible($0) })
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusSection
            metricsSection
            if let metrics = model.metrics {
                disksSection(metrics)
                processesSection(metrics)
                containersSection(metrics)
            }
            projectsSection
            if let error = model.sshLaunchErrorMessage { errorView(error) }
            ForEach(model.errorMessages, id: \.self) { errorView($0) }
        }
        .padding(14)
    }

    private var header: some View {
        HStack {
            Image(systemName: "server.rack").font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text("VPS Monitor").font(.headline)
                Text(model.configuration.sshHost.isEmpty ? "Sin configurar" : model.configuration.sshHost)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(action: model.openSSHSession) {
                if model.isLaunchingSSH {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .buttonStyle(InteractiveIconButtonStyle(size: 32, prominent: true))
            .disabled(!model.canOpenSSHSession || model.isLaunchingSSH)
            .help("Abrir SSH en \(model.configuration.sshTerminal.displayName)")
            .accessibilityLabel("Abrir sesión SSH en \(model.configuration.sshTerminal.displayName)")
            Spacer()
            if model.isLive { LiveBadge() }
            Circle().fill(model.overallState.color).frame(width: 9, height: 9)
                .accessibilityLabel("Estado: \(model.overallState.accessibilityName)")
            Button(action: model.refreshNow) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(model.isRefreshing ? .degrees(360) : .zero)
                    .animation(model.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: model.isRefreshing)
            }
            .buttonStyle(InteractiveIconButtonStyle(size: 30))
            .help("Actualizar ahora")
            .accessibilityLabel("Actualizar ahora")
            Menu {
                Button("Ajustes…") { showSettings() }
                Divider()
                Button("Salir", action: model.quit)
            } label: {
                MenuIconLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Más opciones")
        }.padding(14)
    }

    @ViewBuilder private var statusSection: some View {
        if model.isOffline {
            banner(symbol: "wifi.slash", color: .secondary, title: "Este Mac no tiene conexión",
                   detail: "Las comprobaciones se reanudarán al recuperar la red.")
        }
        ForEach(model.alerts) { alert in
            banner(symbol: alert.severity.symbol, color: alert.severity.color, title: alert.title,
                   detail: alert.detail + " · desde " + alert.since.formatted(date: .omitted, time: .shortened))
        }
    }

    @ViewBuilder private var metricsSection: some View {
        HStack {
            Text("SERVIDOR").font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            Picker("Periodo", selection: $model.historyRange) {
                ForEach(HistoryRange.allCases) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 210)
        }
        if let metrics = model.metrics {
            let series = model.history.series(for: model.historyRange)
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
                           value: model.availability.map(Formatters.preciseAvailability) ?? "—",
                           subtitle: "Encendido " + Formatters.duration(metrics.uptimeSeconds),
                           progress: model.availability.map { $0 / 100 }, positiveProgress: true)
            }
            if metrics.rebootRequired {
                note(symbol: "arrow.triangle.2.circlepath", text: "El servidor necesita reiniciarse para aplicar actualizaciones.")
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.title).foregroundStyle(.secondary)
                Text(model.configuration.sshHost.isEmpty ? "Sin métricas" : "Esperando datos…").font(.headline)
                Text(model.configuration.sshHost.isEmpty ? "Configura el acceso SSH en Ajustes." : "Conectando con \(model.configuration.sshHost).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    @ViewBuilder private func disksSection(_ metrics: ServerMetrics) -> some View {
        if !metrics.disks.isEmpty {
            sectionTitle("DISCOS")
            VStack(spacing: 8) {
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
                            .tint(loadColor(disk.percent, threshold: model.configuration.diskAlertThreshold))
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private func processesSection(_ metrics: ServerMetrics) -> some View {
        if !metrics.processes.isEmpty {
            sectionTitle("PROCESOS")
            VStack(spacing: 6) {
                ForEach(metrics.processes) { process in
                    HStack(spacing: 8) {
                        Text(process.name).font(.callout).lineLimit(1)
                        Text("\(process.pid)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        Spacer()
                        Text(Formatters.bytes(process.memoryBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(Formatters.percent(process.cpuPercent, digits: 1))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private func containersSection(_ metrics: ServerMetrics) -> some View {
        if let containers = metrics.containers {
            let running = containers.filter { $0.state == "running" }.count
            let problems = containers.filter { $0.health == .critical || $0.health == .warning }
            HStack {
                sectionTitle("CONTENEDORES")
                Spacer()
                Text("\(running) en ejecución" + (problems.isEmpty ? "" : " · \(problems.count) con incidencias"))
                    .font(.caption).foregroundStyle(problems.isEmpty ? Color.secondary : Color.orange)
            }
            if !problems.isEmpty || !metrics.failedUnits.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(problems) { container in
                        HStack(spacing: 8) {
                            Circle().fill(container.health.color).frame(width: 7, height: 7)
                            Text(container.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(container.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    ForEach(metrics.failedUnits, id: \.self) { unit in
                        HStack(spacing: 8) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                            Text(unit).font(.callout).lineLimit(1)
                            Spacer()
                            Text("systemd · failed").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("PROYECTOS")
                Spacer(); Text("\(model.projects.count)").font(.caption).foregroundStyle(.secondary)
            }
            if model.projects.isEmpty {
                Text(model.configuration.coolifyURL.isEmpty ? "Configura Coolify para descubrir tus proyectos." : "Sin proyectos en Coolify.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(model.projects) { project in ProjectDisclosure(project: project) }
            }
        }
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                if let lastUpdated = model.lastUpdated {
                    Text("Actualizado " + Formatters.relative(lastUpdated, now: context.date))
                } else {
                    Text("Sin datos todavía")
                }
                Spacer()
                Text(model.isLive ? "En directo · cada \(Int(MonitorConfiguration.liveRefreshInterval)) s"
                                  : "Cada " + Formatters.interval(model.currentInterval))
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(.secondary)
    }

    private func banner(symbol: String, color: Color, title: String, detail: String) -> some View {
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

    private func note(symbol: String, text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
    }

    private func errorView(_ error: String) -> some View {
        Label { Text(error).font(.caption).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

    private func showSettings() {
        SettingsWindowController.shared.show(model: model)
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
    let lines: [(KeyPath<ChartPoint, Double>, Color)]
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
                ForEach(series.points) { point in
                    if lines.count == 1 {
                        AreaMark(x: .value("Hora", point.date), y: .value("Uso", point[keyPath: line.0]),
                                 series: .value("Tramo", "\(index)-\(point.segment)"))
                            .foregroundStyle(LinearGradient(colors: [line.1.opacity(0.28), line.1.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                    }
                    LineMark(x: .value("Hora", point.date), y: .value("Uso", point[keyPath: line.0]),
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

private struct ProjectDisclosure: View {
    let project: CoolifyProject
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(project.health.color).frame(width: 8, height: 8)
                Text(project.name).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }.padding(10)

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
                                        .help("Abrir recurso")
                                }
                            }
                        }
                    }
                }
            }.padding(10)
        }.background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }
    private var summary: String {
        let bad = project.resources.filter { $0.health == .critical }.count
        return bad > 0 ? "\(bad) con problemas" : "\(project.resources.count) recursos"
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
