import Foundation

struct SSHMetricsClient {
    enum SSHError: LocalizedError {
        case invalidConfiguration
        case commandFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: "Completa el host, usuario y puerto SSH."
            case .commandFailed(let message): "SSH: \(message)"
            case .invalidResponse: "El VPS devolvió métricas con un formato inesperado."
            }
        }
    }

    func fetch(configuration: MonitorConfiguration) async throws -> ServerMetrics {
        let script = #"LC_ALL=C; read cpu u n s i w x y z g gn < /proc/stat; t1=$((u+n+s+i+w+x+y+z)); id1=$((i+w)); sleep 1; read cpu u n s i w x y z g gn < /proc/stat; t2=$((u+n+s+i+w+x+y+z)); id2=$((i+w)); dt=$((t2-t1)); di=$((id2-id1)); awk -v dt=$dt -v di=$di 'BEGIN { printf "CPU=%.1f\n", dt ? (dt-di)*100/dt : 0 }'; awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "MEM=%d,%d\n",(t-a)*1024,t*1024}' /proc/meminfo; df -B1 --output=used,size / | tail -1 | awk '{printf "DISK=%s,%s\n",$1,$2}'; printf 'LOAD='; cut -d' ' -f1-3 /proc/loadavg; printf 'UPTIME='; uptime -p"#
        let launchCommand: SSHLaunchCommand
        do {
            launchCommand = try metricsCommand(configuration: configuration, remoteCommand: script)
        } catch {
            throw SSHError.invalidConfiguration
        }
        let output = try await runSSH(launchCommand)
        return try parse(output)
    }

    func metricsCommand(configuration: MonitorConfiguration, remoteCommand: String) throws -> SSHLaunchCommand {
        let interactive = try SSHCommandBuilder().build(configuration: configuration)
        let options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        return SSHLaunchCommand(
            executable: interactive.executable,
            arguments: options + interactive.arguments + [remoteCommand]
        )
    }

    func parse(_ output: String) throws -> ServerMetrics {
        var metrics = ServerMetrics()
        for line in output.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "CPU": metrics.cpuPercent = Double(pair[1]) ?? 0
            case "MEM":
                let values = pair[1].split(separator: ",").compactMap { Int64($0) }
                if values.count == 2 { metrics.usedMemoryBytes = values[0]; metrics.totalMemoryBytes = values[1] }
            case "DISK":
                let values = pair[1].split(separator: ",").compactMap { Int64($0) }
                if values.count == 2 { metrics.usedDiskBytes = values[0]; metrics.totalDiskBytes = values[1] }
            case "LOAD": metrics.load = pair[1]
            case "UPTIME": metrics.uptime = pair[1].replacingOccurrences(of: "up ", with: "")
            default: break
            }
        }
        guard metrics.totalMemoryBytes > 0, metrics.totalDiskBytes > 0 else { throw SSHError.invalidResponse }
        return metrics
    }

    private func runSSH(_ launchCommand: SSHLaunchCommand) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe(), stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: launchCommand.executable)
            process.arguments = launchCommand.arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { process in
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let error = stderr.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: out, as: UTF8.self))
                } else {
                    continuation.resume(throwing: SSHError.commandFailed(String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
