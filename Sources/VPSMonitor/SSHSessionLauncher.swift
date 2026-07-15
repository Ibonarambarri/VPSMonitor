import AppKit
import Foundation

struct SSHLaunchCommand: Equatable {
    let executable: String
    let arguments: [String]

    var shellCommand: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    var warpShellCommand: String {
        var warpArguments = arguments
        if warpArguments.count >= 2, warpArguments[warpArguments.count - 2] == "--" {
            warpArguments.remove(at: warpArguments.count - 2)
        }
        return (["ssh"] + warpArguments).map(Self.shellWord).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellWord(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-[]")
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { !safe.contains($0) }) else {
            return shellQuote(value)
        }
        return value
    }
}

struct SSHCommandBuilder {
    enum ValidationError: LocalizedError, Equatable {
        case missingHost
        case invalidHost
        case missingUser
        case invalidUser
        case invalidPort
        case invalidKeyPath

        var errorDescription: String? {
            switch self {
            case .missingHost: "Configura el host SSH antes de abrir una sesión."
            case .invalidHost: "El host SSH contiene caracteres no válidos."
            case .missingUser: "Configura el usuario SSH antes de abrir una sesión."
            case .invalidUser: "El usuario SSH contiene caracteres no válidos."
            case .invalidPort: "El puerto SSH debe ser un número entre 1 y 65535."
            case .invalidKeyPath: "La ruta de la clave SSH contiene caracteres no válidos."
            }
        }
    }

    func build(configuration: MonitorConfiguration) throws -> SSHLaunchCommand {
        let host = configuration.sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = configuration.sshUser.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty else { throw ValidationError.missingHost }
        guard isValid(host, allowed: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]%"),
              host.first != "-" else { throw ValidationError.invalidHost }
        guard !user.isEmpty else { throw ValidationError.missingUser }
        guard isValid(user, allowed: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"),
              user.first != "-" else { throw ValidationError.invalidUser }
        guard let port = Int(configuration.sshPort), (1...65535).contains(port) else {
            throw ValidationError.invalidPort
        }

        let configuredKey = configuration.sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ValidationError.invalidKeyPath
        }

        var arguments = ["-p", String(port)]
        if !configuredKey.isEmpty {
            let keyPath = NSString(string: configuredKey).expandingTildeInPath
            arguments += ["-o", "IdentitiesOnly=yes", "-i", keyPath]
        }
        arguments += ["--", "\(user)@\(host)"]
        return SSHLaunchCommand(executable: "/usr/bin/ssh", arguments: arguments)
    }

    func isValid(configuration: MonitorConfiguration) -> Bool {
        (try? build(configuration: configuration)) != nil
    }

    private func isValid(_ value: String, allowed: String) -> Bool {
        let allowedCharacters = CharacterSet(charactersIn: allowed)
        return !value.unicodeScalars.contains { !allowedCharacters.contains($0) }
    }
}

struct SSHSessionLauncher {
    enum LaunchError: LocalizedError {
        case privateKeyNotFound(String)
        case terminalUnavailable(String)
        case automationDenied
        case warpConfiguration(String)
        case invalidCustomExecutable
        case invalidCustomArguments
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .privateKeyNotFound(let path):
                "No se encontró la clave privada SSH en \(path)."
            case .terminalUnavailable(let terminal):
                "No se encontró \(terminal) en este Mac."
            case .automationDenied:
                "macOS bloqueó Terminal. Permite VPS Monitor en Ajustes del Sistema > Privacidad y seguridad > Automatización."
            case .warpConfiguration(let message):
                "No se pudo preparar Warp: \(message)"
            case .invalidCustomExecutable:
                "Indica una ruta absoluta a un ejecutable para la terminal personalizada."
            case .invalidCustomArguments:
                "Los argumentos personalizados deben incluir {ssh} en una línea independiente."
            case .launchFailed(let message):
                "No se pudo abrir la sesión SSH: \(message)"
            }
        }
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func launch(configuration: MonitorConfiguration) async throws {
        let command = try SSHCommandBuilder().build(configuration: configuration)
        try validateKeyIfPresent(in: command)

        switch configuration.sshTerminal {
        case .appleTerminal:
            try await launchInAppleTerminal(command)
        case .warp:
            try await launchInWarp(command, host: configuration.sshHost)
        case .custom:
            try launchCustom(command, configuration: configuration)
        }
    }

    func isConfigured(configuration: MonitorConfiguration) -> Bool {
        guard let command = try? SSHCommandBuilder().build(configuration: configuration) else { return false }
        guard configuration.sshTerminal == .custom else { return true }
        return (try? customInvocation(for: command, configuration: configuration)) != nil
    }

    private func validateKeyIfPresent(in command: SSHLaunchCommand) throws {
        guard let keyIndex = command.arguments.firstIndex(of: "-i"),
              command.arguments.indices.contains(keyIndex + 1) else { return }
        let path = command.arguments[keyIndex + 1]
        guard fileManager.fileExists(atPath: path) else { throw LaunchError.privateKeyNotFound(path) }
    }

    private func launchInAppleTerminal(_ command: SSHLaunchCommand) async throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil else {
            throw LaunchError.terminalUnavailable("Terminal de Apple")
        }

        let script = """
        on run argv
            tell application id "com.apple.Terminal"
                activate
                do script (item 1 of argv)
            end tell
        end run
        """
        do {
            try await runAndWait(executable: "/usr/bin/osascript", arguments: ["-e", script, "--", command.shellCommand])
        } catch let error as ProcessLaunchError where error.message.contains("-1743") {
            throw LaunchError.automationDenied
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }
    }

    private func launchInWarp(_ command: SSHLaunchCommand, host: String) async throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable") != nil else {
            throw LaunchError.terminalUnavailable("Warp")
        }

        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".warp", isDirectory: true)
            .appendingPathComponent("tab_configs", isDirectory: true)
        let file = directory.appendingPathComponent("com_vpsmonitor_app_ssh.toml")
        let contents = """
        name = \(tomlString("VPS Monitor SSH"))
        title = \(tomlString(host))

        [[panes]]
        id = "ssh"
        type = "terminal"
        commands = [\(tomlString(command.warpShellCommand))]
        is_focused = true
        """

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw LaunchError.warpConfiguration(error.localizedDescription)
        }

        do {
            try await runAndWait(
                executable: "/usr/bin/open",
                arguments: ["-b", "dev.warp.Warp-Stable", "warp://tab_config/com_vpsmonitor_app_ssh?new_window=true"]
            )
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }
    }

    private func launchCustom(_ command: SSHLaunchCommand, configuration: MonitorConfiguration) throws {
        let invocation = try customInvocation(for: command, configuration: configuration)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        do {
            try process.run()
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }
    }

    func customInvocation(for command: SSHLaunchCommand, configuration: MonitorConfiguration) throws -> SSHLaunchCommand {
        let rawExecutable = configuration.customTerminalExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = NSString(string: rawExecutable).expandingTildeInPath
        guard executable.hasPrefix("/"), fileManager.isExecutableFile(atPath: executable) else {
            throw LaunchError.invalidCustomExecutable
        }

        let lines = configuration.customTerminalArguments
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.filter({ $0 == "{ssh}" }).count == 1,
              !lines.contains(where: { $0 != "{ssh}" && $0.contains("{ssh}") }) else {
            throw LaunchError.invalidCustomArguments
        }

        var arguments: [String] = []
        for line in lines {
            if line == "{ssh}" {
                arguments.append(command.executable)
                arguments.append(contentsOf: command.arguments)
            } else {
                arguments.append(line)
            }
        }
        return SSHLaunchCommand(executable: executable, arguments: arguments)
    }

    private func tomlString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x00...0x1F, 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private func runAndWait(executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { process in
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                let error = stderr.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else {
                    let message = String(decoding: error.isEmpty ? output : error, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ProcessLaunchError(message: message.isEmpty ? "código \(process.terminationStatus)" : message))
                    return
                }
                continuation.resume(returning: ())
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private struct ProcessLaunchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
