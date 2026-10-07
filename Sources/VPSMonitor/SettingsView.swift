import SwiftUI

struct SettingsView: View {
    private enum Item: Hashable {
        case general
        case vps(UUID)
    }

    @ObservedObject private var model: MonitorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [VPSProfile]
    @State private var tokens: [UUID: String]
    @State private var preferences: MonitorPreferences
    @State private var selectedProfileID: UUID
    @State private var selection: Item?
    var onClose: (() -> Void)? = nil

    init(model: MonitorViewModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        _profiles = State(initialValue: model.profiles)
        _tokens = State(initialValue: Dictionary(uniqueKeysWithValues: model.profiles.map { ($0.id, model.token(for: $0.id)) }))
        _preferences = State(initialValue: model.preferences)
        _selectedProfileID = State(initialValue: model.selectedProfileID)
        _selection = State(initialValue: .vps(model.selectedProfileID))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 200)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if let invalid = firstInvalidProfile {
                    Label("Revisa \(invalid.displayName): \(validationMessage(invalid) ?? "")", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer()
                Button("Cancelar", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Guardar y probar", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 640)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("General") {
                    Label("Actualización y alertas", systemImage: "gearshape").tag(Item.general)
                }
                Section("VPS configurados") {
                    ForEach(profiles) { profile in
                        HStack(spacing: 8) {
                            Circle().fill(model.monitors[profile.id]?.overallState.color ?? .secondary).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.displayName).lineLimit(1)
                                Text(profile.configuration.sshHost.isEmpty ? "Sin host" : profile.configuration.sshHost)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if validationMessage(profile) != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                            }
                        }
                        .tag(Item.vps(profile.id))
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                Button(action: addProfile) { Image(systemName: "plus").frame(width: 22, height: 20) }
                    .help("Añadir otro VPS")
                Button(action: removeSelectedProfile) { Image(systemName: "minus").frame(width: 22, height: 20) }
                    .help(profiles.count > 1 ? "Eliminar el VPS seleccionado" : "Debe existir al menos un VPS")
                    .disabled(profiles.count <= 1 || selectedVPSIndex == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general, nil:
            generalForm
        case .vps(let id):
            if let index = profiles.firstIndex(where: { $0.id == id }) {
                VPSForm(profile: $profiles[index],
                        token: Binding(get: { tokens[id] ?? "" }, set: { tokens[id] = $0 }),
                        isShownInPanel: selectedProfileID == id,
                        showInPanel: { selectedProfileID = id })
                    .id(id)
            } else {
                generalForm
            }
        }
    }

    private var generalForm: some View {
        Form {
            Section("Actualización") {
                Picker("Comprobar cada VPS", selection: $preferences.refreshInterval) {
                    ForEach(MonitorPreferences.refreshIntervals, id: \.self) { interval in
                        Text("Cada " + Formatters.interval(interval)).tag(interval)
                    }
                }
                Toggle("En directo con el panel abierto", isOn: $preferences.liveWhileOpen)
                Text("Con el panel abierto, el VPS seleccionado se actualiza cada \(Int(MonitorPreferences.liveRefreshInterval)) s reutilizando una única conexión SSH. Los demás siguen comprobándose en segundo plano. Si una comprobación falla, se repite en 15 s como máximo.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Mostrar CPU en la barra de menús", isOn: $preferences.showCPUInMenuBar)
            }
            Section("Alertas") {
                Toggle("Notificaciones de macOS", isOn: $preferences.notificationsEnabled)
                thresholdSlider("CPU sostenida", value: $preferences.cpuAlertThreshold)
                thresholdSlider("Memoria sostenida", value: $preferences.memoryAlertThreshold)
                thresholdSlider("Disco", value: $preferences.diskAlertThreshold)
                Text("CPU y memoria avisan tras \(Int(AlertEngine.sustainedLoadDuration / 60)) minutos por encima del umbral. También se avisa si un VPS deja de responder, un recurso de Coolify o un contenedor falla, o hay servicios systemd caídos, y cuando se resuelve.")
                    .font(.caption).foregroundStyle(.secondary)
                if !AlertNotifier.isAvailable {
                    Text("Las notificaciones solo funcionan con la app instalada mediante Scripts/install.sh.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func thresholdSlider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 50...100, step: 5).frame(width: 180)
                Text(Formatters.percent(value.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }

    // MARK: Actions

    private var selectedVPSIndex: Int? {
        guard case .vps(let id) = selection else { return nil }
        return profiles.firstIndex { $0.id == id }
    }

    private var firstInvalidProfile: VPSProfile? {
        profiles.first { validationMessage($0) != nil }
    }

    private func validationMessage(_ profile: VPSProfile) -> String? {
        let configuration = profile.configuration
        if configuration.sshHost.isEmpty && configuration.coolifyURL.isEmpty { return nil }
        if !configuration.sshHost.isEmpty {
            do { _ = try SSHCommandBuilder().build(configuration: configuration) }
            catch { return error.localizedDescription }
        }
        if let url = configuration.coolifyURL.nonEmpty, URL(string: url)?.scheme == nil {
            return "la URL de Coolify debe empezar por https://"
        }
        return nil
    }

    private func addProfile() {
        var configuration = MonitorConfiguration()
        // New servers usually share the terminal of the current one.
        if let current = profiles.first(where: { $0.id == selectedProfileID }) {
            configuration.sshTerminal = current.configuration.sshTerminal
            configuration.customTerminalExecutable = current.configuration.customTerminalExecutable
            configuration.customTerminalArguments = current.configuration.customTerminalArguments
        }
        let profile = VPSProfile(name: "VPS \(profiles.count + 1)", configuration: configuration)
        profiles.append(profile)
        tokens[profile.id] = ""
        selection = .vps(profile.id)
    }

    private func removeSelectedProfile() {
        guard profiles.count > 1, let index = selectedVPSIndex else { return }
        let removed = profiles.remove(at: index)
        tokens[removed.id] = nil
        if selectedProfileID == removed.id { selectedProfileID = profiles[0].id }
        selection = .vps(profiles[min(index, profiles.count - 1)].id)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func save() {
        model.save(profiles: profiles, tokens: tokens, selectedID: selectedProfileID, preferences: preferences)
        close()
    }
}

/// The settings of one VPS, with a connection test that does not save anything.
private struct VPSForm: View {
    @Binding var profile: VPSProfile
    @Binding var token: String
    let isShownInPanel: Bool
    let showInPanel: () -> Void

    @State private var sshTest: TestState = .idle
    @State private var coolifyTest: TestState = .idle

    private enum TestState: Equatable {
        case idle, running, success(String), failure(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $profile.name, prompt: Text("Producción"))
                Text("Este nombre aparece en el selector principal y en las notificaciones.")
                    .font(.caption).foregroundStyle(.secondary)
                if !isShownInPanel {
                    Button("Mostrar este VPS en el panel", action: showInPanel)
                }
            }
            Section("Servidor SSH") {
                TextField("Host o IP", text: $profile.configuration.sshHost, prompt: Text("vps.ejemplo.com"))
                HStack {
                    TextField("Usuario", text: $profile.configuration.sshUser)
                    TextField("Puerto", text: $profile.configuration.sshPort).frame(width: 90)
                }
                TextField("Clave privada", text: $profile.configuration.sshKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                testRow(state: sshTest, label: "Probar SSH", action: testSSH)
                    .disabled(profile.configuration.sshHost.isEmpty)
            }
            Section("Coolify") {
                TextField("URL", text: $profile.configuration.coolifyURL, prompt: Text("https://coolify.ejemplo.com"))
                SecureField("Token API con permiso read", text: $token)
                Text("Cada VPS guarda su token por separado en Keychain.").font(.caption).foregroundStyle(.secondary)
                testRow(state: coolifyTest, label: "Probar Coolify", action: testCoolify)
                    .disabled(profile.configuration.coolifyURL.isEmpty)
            }
            Section("Terminal SSH") {
                Picker("Abrir sesiones con", selection: $profile.configuration.sshTerminal) {
                    ForEach(SSHTerminal.allCases) { terminal in
                        Text(terminal.displayName).tag(terminal)
                    }
                }
                switch profile.configuration.sshTerminal {
                case .appleTerminal:
                    Text("macOS puede solicitar permiso para que VPS Monitor controle Terminal la primera vez.")
                        .font(.caption).foregroundStyle(.secondary)
                case .warp:
                    Text("Se abrirá una ventana nueva mediante un Tab Config administrado por VPS Monitor.")
                        .font(.caption).foregroundStyle(.secondary)
                case .custom:
                    TextField("Ejecutable absoluto", text: $profile.configuration.customTerminalExecutable)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Argumentos, uno por línea").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $profile.configuration.customTerminalArguments)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 66)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        Text("Incluye {ssh} en una línea independiente. Ejemplo para un lanzador compatible: -e ↵ {ssh}")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: profile.configuration) { _ in
            sshTest = .idle
            coolifyTest = .idle
        }
        .onChange(of: token) { _ in coolifyTest = .idle }
    }

    private func testRow(state: TestState, label: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(label, action: action).disabled(state == .running)
            switch state {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                    .lineLimit(3).textSelection(.enabled)
            }
        }
    }

    private func testSSH() {
        let configuration = profile.configuration
        sshTest = .running
        Task { @MainActor in
            do {
                let metrics = try await SSHMetricsClient().fetch(configuration: configuration)
                var parts = ["Conectado", "\(metrics.cores) núcleos", Formatters.bytes(metrics.totalMemoryBytes) + " RAM"]
                if metrics.containers != nil { parts.append("Docker accesible") }
                sshTest = .success(parts.joined(separator: " · "))
            } catch {
                sshTest = .failure(error.localizedDescription)
            }
        }
    }

    private func testCoolify() {
        let url = profile.configuration.coolifyURL
        let token = token
        coolifyTest = .running
        Task { @MainActor in
            do {
                let projects = try await CoolifyClient().fetchProjects(baseURL: url, token: token)
                coolifyTest = .success("\(projects.count) proyectos · \(projects.flatMap(\.resources).count) recursos")
            } catch {
                coolifyTest = .failure(error.localizedDescription)
            }
        }
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
            newWindow.setContentSize(NSSize(width: 720, height: 640))
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
