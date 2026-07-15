import Charts
import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var model: MonitorViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    metricsSection
                    projectsSection
                    if let error = model.sshLaunchErrorMessage { errorView(error) }
                    if let error = model.errorMessage { errorView(error) }
                }
                .padding(14)
            }
        }
        .frame(width: 380, height: 520)
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
            Circle().fill(model.overallState.color).frame(width: 9, height: 9)
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(model.isRefreshing ? .degrees(360) : .zero)
                    .animation(.linear(duration: 0.55), value: model.isRefreshing)
            }
            .buttonStyle(InteractiveIconButtonStyle(size: 30))
            .disabled(model.isRefreshing)
            .help("Actualizar ahora")
            .accessibilityLabel("Actualizar ahora")
            Menu {
                Button("Ajustes") { showSettings() }
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

    @ViewBuilder private var metricsSection: some View {
        Text("SERVIDOR").font(.caption.bold()).foregroundStyle(.secondary)
        if let metrics = model.metrics {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                HistoryMetricCard(title: "CPU", percent: metrics.cpuPercent,
                                  samples: model.chartMetricSamples, value: \.cpu, tint: .blue)
                HistoryMetricCard(title: "RAM", percent: metrics.memoryPercent,
                                  samples: model.chartMetricSamples, value: \.memory, tint: .purple,
                                  subtitle: bytePair(metrics.usedMemoryBytes, metrics.totalMemoryBytes))
                MetricCard(title: "Disco", value: bytePair(metrics.usedDiskBytes, metrics.totalDiskBytes), progress: metrics.diskPercent / 100)
                MetricCard(title: "Uptime", value: percent(model.uptimePercent), subtitle: metrics.uptime,
                           progress: model.uptimePercent / 100, positiveProgress: true)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.title).foregroundStyle(.secondary)
                Text("Sin métricas").font(.headline)
                Text("Configura el acceso SSH en Ajustes.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROYECTOS").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer(); Text("\(model.projects.count)").font(.caption).foregroundStyle(.secondary)
            }
            if model.projects.isEmpty {
                Text("Configura Coolify para descubrir tus proyectos.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(model.projects) { project in ProjectDisclosure(project: project) }
            }
        }
    }

    private func errorView(_ error: String) -> some View {
        Label { Text(error).font(.caption).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
    private func showSettings() {
        SettingsWindowController.shared.show(model: model)
    }
    private func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) + "%" }
    private func bytePair(_ used: Int64, _ total: Int64) -> String { ByteCountFormatter.string(fromByteCount: used, countStyle: .memory) + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .memory) }
}

private struct MetricCard: View {
    let title: String, value: String
    var subtitle: String? = nil
    var progress: Double? = nil
    var positiveProgress = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.65)
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(positiveProgress ? (progress >= 0.99 ? .green : progress >= 0.95 ? .orange : .red) : (progress >= 0.9 ? .red : progress >= 0.8 ? .orange : .accentColor))
            }
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }.padding(10).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct HistoryMetricCard: View {
    let title: String
    let percent: Double
    let samples: [ChartMetricSample]
    let value: KeyPath<ChartMetricSample, Double>
    let tint: Color
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(percent.formatted(.number.precision(.fractionLength(0))) + "%")
                    .font(.system(.body, design: .rounded).bold())
            }
            Chart(samples) { sample in
                AreaMark(x: .value("Hora", sample.date), y: .value("Uso", sample[keyPath: value]))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Hora", sample.date), y: .value("Uso", sample[keyPath: value]))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if sample.id == samples.last?.id {
                    PointMark(x: .value("Hora", sample.date), y: .value("Uso", sample[keyPath: value]))
                        .foregroundStyle(tint)
                }
            }
            .chartXScale(domain: Date().addingTimeInterval(-3600)...Date())
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 42)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text("Última hora · cada 1 min").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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
