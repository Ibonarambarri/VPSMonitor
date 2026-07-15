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
                LabeledContent("Estado del servidor", value: "Cada 1 minuto")
                LabeledContent("Gráficas CPU y RAM", value: "Cada 1 minuto")
                Text("Si una comprobación falla, se repite a los 15 segundos.")
                    .font(.caption).foregroundStyle(.secondary)
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
        }.formStyle(.grouped).padding().frame(width: 520, height: 560)
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
            newWindow.setContentSize(NSSize(width: 520, height: 560))
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
