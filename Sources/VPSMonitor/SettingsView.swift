import SwiftUI

struct SettingsView: View {
    @ObservedObject private var model: MonitorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: MonitorConfiguration
    @State private var token: String
    var onClose: (() -> Void)? = nil

    init(model: MonitorViewModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        _configuration = State(initialValue: model.configuration)
        _token = State(initialValue: model.token)
    }

    var body: some View {
        Form {
            Section("Coolify") {
                TextField("URL (https://coolify.ejemplo.com)", text: $configuration.coolifyURL)
                SecureField("Token API con permiso read", text: $token)
            }
            Section("Servidor SSH") {
                TextField("Host o IP", text: $configuration.sshHost)
                HStack { TextField("Usuario", text: $configuration.sshUser); TextField("Puerto", text: $configuration.sshPort).frame(width: 70) }
                TextField("Ruta de la clave privada", text: $configuration.sshKeyPath)
            }
            Section("Terminal SSH") {
                Picker("Abrir sesiones con", selection: $configuration.sshTerminal) {
                    ForEach(SSHTerminal.allCases) { terminal in
                        Text(terminal.displayName).tag(terminal)
                    }
                }

                switch configuration.sshTerminal {
                case .appleTerminal:
                    Text("macOS puede solicitar permiso para que VPS Monitor controle Terminal la primera vez.")
                        .font(.caption).foregroundStyle(.secondary)
                case .warp:
                    Text("Se abrirá una ventana nueva mediante un Tab Config administrado por VPS Monitor.")
                        .font(.caption).foregroundStyle(.secondary)
                case .custom:
                    TextField("Ejecutable absoluto", text: $configuration.customTerminalExecutable)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Argumentos, uno por línea").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $configuration.customTerminalArguments)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 66)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        Text("Incluye {ssh} en una línea independiente. Ejemplo para un lanzador compatible: -e ↵ {ssh}")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Actualización") {
                Picker("Comprobar el servidor", selection: $configuration.refreshInterval) {
                    ForEach(MonitorConfiguration.refreshIntervals, id: \.self) { interval in
                        Text("Cada " + Formatters.interval(interval)).tag(interval)
                    }
                }
                Toggle("En directo con el panel abierto", isOn: $configuration.liveWhileOpen)
                Text("Con el panel abierto, las métricas se actualizan cada \(Int(MonitorConfiguration.liveRefreshInterval)) s reutilizando una única conexión SSH. Si una comprobación falla, se repite en 15 s como máximo.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Mostrar CPU en la barra de menús", isOn: $configuration.showCPUInMenuBar)
            }
            Section("Alertas") {
                Toggle("Notificaciones de macOS", isOn: $configuration.notificationsEnabled)
                thresholdSlider("CPU sostenida", value: $configuration.cpuAlertThreshold)
                thresholdSlider("Memoria sostenida", value: $configuration.memoryAlertThreshold)
                thresholdSlider("Disco", value: $configuration.diskAlertThreshold)
                Text("CPU y memoria avisan tras \(Int(AlertEngine.sustainedLoadDuration / 60)) minutos por encima del umbral. También se avisa si el servidor deja de responder, un recurso de Coolify o un contenedor falla, o hay servicios systemd caídos.")
                    .font(.caption).foregroundStyle(.secondary)
                if !AlertNotifier.isAvailable {
                    Text("Las notificaciones solo funcionan con la app instalada mediante Scripts/install.sh.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button("Cancelar", action: close)
                    .buttonStyle(.bordered)
                Button("Guardar y probar", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }.formStyle(.grouped).padding().frame(width: 540, height: 680)
    }

    private func thresholdSlider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 50...100, step: 5).frame(width: 180)
                Text(Formatters.percent(value.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func save() {
        model.configuration = configuration
        model.token = token
        model.save()
        close()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(model: MonitorViewModel) {
        if window == nil {
            let rootView = SettingsView(model: model, onClose: { [weak self] in
                self?.window?.close()
            })
            let hostingController = NSHostingController(rootView: rootView)
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "Ajustes de VPS Monitor"
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.setContentSize(NSSize(width: 540, height: 680))
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.center()
            self.window = newWindow
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
