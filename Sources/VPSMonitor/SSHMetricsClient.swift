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

    /// POSIX sh script sent on stdin, so it does not depend on the remote login shell.
    /// CPU, network and per-process usage are sampled over one second; everything is
    /// printed as KEY=VALUE lines and interpreted by `parse`.
    static let remoteScript = #"""
    export LC_ALL=C
    snap() { cat /proc/[0-9]*/stat 2>/dev/null | awk '{ if (!match($0, /\(.*\)/)) next; n = substr($0, RSTART + 1, RLENGTH - 2); gsub(/[ \t|]/, "_", n); split(substr($0, RSTART + RLENGTH + 1), f, " "); printf "%s %.0f %.0f %s\n", $1, f[12] + f[13], f[22], n }'; }
    net() { awk 'NR > 2 { sub(/^ */, ""); split($0, p, ":"); i = p[1]; if (i == "lo" || i ~ /^(veth|docker|br-|virbr|cni|flannel|cali|vxlan|tun|tap|wg|tailscale|zt)/) next; split(p[2], v, " "); rx += v[1]; tx += v[9] } END { printf "%.0f %.0f\n", rx, tx }' /proc/net/dev; }
    c1=$(head -n 1 /proc/stat); n1=$(net); p1=$(snap)
    sleep 1
    c2=$(head -n 1 /proc/stat); n2=$(net)
    snap | P1="$p1" awk 'BEGIN { n = split(ENVIRON["P1"], l, "\n"); for (i = 1; i <= n; i++) { split(l[i], a, " "); t[a[1]] = a[2] } } ($1 in t) { printf "%.0f|%.0f|%s|%s\n", $2 - t[$1], $3, $1, $4 }' | sort -t '|' -k1,1nr -k2,2nr | head -n 6 | sed 's/^/PROC=/'
    echo "STAT1=$c1"; echo "STAT2=$c2"; echo "NET1=$n1"; echo "NET2=$n2"
    echo "CORES=$(grep -c '^processor' /proc/cpuinfo)"
    echo "PAGESIZE=$(getconf PAGESIZE 2>/dev/null || echo 4096)"
    awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ { v[$1] = $2 } END { printf "MEM=%.0f %.0f %.0f %.0f\n", v["MemTotal:"], v["MemAvailable:"], v["SwapTotal:"], v["SwapFree:"] }' /proc/meminfo
    echo "LOAD=$(cut -d ' ' -f 1-3 /proc/loadavg)"
    echo "UPTIME=$(cut -d ' ' -f 1 /proc/uptime)"
    t=""; command -v timeout >/dev/null 2>&1 && t="timeout 5"
    $t df -kP 2>/dev/null | awk 'NR > 1 && $1 ~ /^\// && $1 !~ /^\/dev\/loop/ { m = $6; for (i = 7; i <= NF; i++) m = m " " $i; printf "DISK=%s|%.0f|%.0f|%.0f|%s\n", $1, $2 * 1024, $3 * 1024, $4 * 1024, m }'
    if [ -f /var/run/reboot-required ]; then echo "REBOOT=1"; fi
    if command -v systemctl >/dev/null 2>&1; then $t systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk 'NF { print "FAILED=" $1 }'; fi
    if command -v docker >/dev/null 2>&1 && out=$($t docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null); then
        echo "DOCKER=1"; printf '%s\n' "$out" | grep . | sed 's/^/CTR=/'
    fi
    exit 0
    """#

    func fetch(configuration: MonitorConfiguration) async throws -> ServerMetrics {
        let launchCommand: SSHLaunchCommand
        do {
            launchCommand = try metricsCommand(configuration: configuration, remoteCommand: "sh -s")
        } catch {
            throw SSHError.invalidConfiguration
        }
        let output = try await ProcessRunner.run(executable: launchCommand.executable,
                                                 arguments: launchCommand.arguments,
                                                 input: Data(Self.remoteScript.utf8),
                                                 timeout: 25)
        guard output.status == 0 else {
            let message = output.standardError
            throw SSHError.commandFailed(message.isEmpty ? "código de salida \(output.status)" : message)
        }
        return try parse(output.standardOutput)
    }

    func metricsCommand(configuration: MonitorConfiguration, remoteCommand: String) throws -> SSHLaunchCommand {
        let interactive = try SSHCommandBuilder().build(configuration: configuration)
        let options = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                       "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
            + Self.multiplexingOptions()
        return SSHLaunchCommand(
            executable: interactive.executable,
            arguments: options + interactive.arguments + [remoteCommand]
        )
    }

    /// Closes the shared connection, e.g. after the Mac wakes up or changes network,
    /// so the next check does not reuse a dead TCP session.
    func resetConnection(configuration: MonitorConfiguration) async {
        guard let command = try? metricsCommand(configuration: configuration, remoteCommand: ""),
              command.arguments.contains(where: { $0.hasPrefix("ControlPath=") }) else { return }
        var arguments = command.arguments
        arguments.removeLast()
        arguments.insert(contentsOf: ["-O", "exit"], at: 0)
        _ = try? await ProcessRunner.run(executable: command.executable, arguments: arguments, timeout: 5)
    }

    /// Reuses one SSH connection between checks, which makes frequent polling cheap.
    static func multiplexingOptions() -> [String] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("vpsm", isDirectory: true)
        // Unix socket paths are limited to 103 bytes. %C expands to 40 characters and
        // ssh appends a 17-character temporary suffix while creating the socket.
        guard directory.path.utf8.count + 1 + 40 + 17 <= 103 else { return [] }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return []
        }
        return ["-o", "ControlMaster=auto",
                "-o", "ControlPath=\(directory.path)/%C",
                "-o", "ControlPersist=300"]
    }

    func parse(_ output: String) throws -> ServerMetrics {
        var metrics = ServerMetrics()
        var stat1: [Double] = [], stat2: [Double] = []
        var net1: [Double] = [], net2: [Double] = []
        var pageSize = 4096.0
        var rawProcesses: [(ticks: Double, pages: Double, pid: Int, name: String)] = []
        var disks: [DiskUsage] = []
        var containers: [ContainerStatus] = []
        var dockerAvailable = false

        for line in output.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let value = pair[1]
            switch pair[0] {
            case "STAT1": stat1 = numbers(value.split(separator: " ").dropFirst().joined(separator: " "))
            case "STAT2": stat2 = numbers(value.split(separator: " ").dropFirst().joined(separator: " "))
            case "NET1": net1 = numbers(value)
            case "NET2": net2 = numbers(value)
            case "CORES": metrics.cores = Int(value) ?? 0
            case "PAGESIZE": pageSize = Double(value) ?? 4096
            case "MEM":
                let values = numbers(value)
                if values.count == 4 {
                    metrics.totalMemoryBytes = Int64(values[0] * 1024)
                    metrics.usedMemoryBytes = Int64(max(values[0] - values[1], 0) * 1024)
                    metrics.totalSwapBytes = Int64(values[2] * 1024)
                    metrics.usedSwapBytes = Int64(max(values[2] - values[3], 0) * 1024)
                }
            case "LOAD": metrics.load = numbers(value)
            case "UPTIME": metrics.uptimeSeconds = Double(value) ?? 0
            case "DISK":
                let fields = value.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                if fields.count == 5, let total = Int64(fields[1]), let used = Int64(fields[2]), let available = Int64(fields[3]) {
                    disks.append(DiskUsage(filesystem: fields[0], mountPoint: fields[4], usedBytes: used,
                                           availableBytes: available, totalBytes: total))
                }
            case "PROC":
                let fields = value.split(separator: "|", maxSplits: 3).map(String.init)
                if fields.count == 4, let ticks = Double(fields[0]), let pages = Double(fields[1]), let pid = Int(fields[2]) {
                    rawProcesses.append((ticks, pages, pid, fields[3]))
                }
            case "REBOOT": metrics.rebootRequired = true
            case "FAILED": metrics.failedUnits.append(value)
            case "DOCKER": dockerAvailable = true
            case "CTR":
                let fields = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                if fields.count == 3 { containers.append(ContainerStatus(name: fields[0], state: fields[1], status: fields[2])) }
            default: break
            }
        }

        guard stat1.count >= 4, stat2.count >= 4, metrics.totalMemoryBytes > 0 else { throw SSHError.invalidResponse }

        // user nice system idle iowait irq softirq steal; guest time is already part of user.
        func field(_ values: [Double], _ index: Int) -> Double { values.indices.contains(index) ? values[index] : 0 }
        let total1 = stat1.prefix(8).reduce(0, +), total2 = stat2.prefix(8).reduce(0, +)
        let elapsedTicks = total2 - total1
        if elapsedTicks > 0 {
            let idle = (field(stat2, 3) + field(stat2, 4)) - (field(stat1, 3) + field(stat1, 4))
            metrics.cpuPercent = clampPercent((elapsedTicks - idle) / elapsedTicks * 100)
            metrics.iowaitPercent = clampPercent((field(stat2, 4) - field(stat1, 4)) / elapsedTicks * 100)
            metrics.stealPercent = clampPercent((field(stat2, 7) - field(stat1, 7)) / elapsedTicks * 100)
            metrics.processes = rawProcesses.map { process in
                ProcessUsage(pid: process.pid, name: process.name,
                             cpuPercent: clampPercent(process.ticks / elapsedTicks * 100),
                             memoryBytes: Int64(process.pages * pageSize))
            }
            .sorted { ($0.cpuPercent, $0.memoryBytes) > ($1.cpuPercent, $1.memoryBytes) }
            .prefix(5).map { $0 }
        }

        // /proc/stat counts USER_HZ (100) ticks per core.
        let seconds = metrics.cores > 0 && elapsedTicks > 0 ? elapsedTicks / Double(metrics.cores) / 100 : 1
        if net1.count == 2, net2.count == 2, seconds > 0 {
            metrics.networkReceiveRate = max(net2[0] - net1[0], 0) / seconds
            metrics.networkTransmitRate = max(net2[1] - net1[1], 0) / seconds
        }

        // Bind mounts report the same device more than once; keep its shortest mount point.
        metrics.disks = Dictionary(grouping: disks, by: \.filesystem)
            .compactMap { $0.value.min { $0.mountPoint.count < $1.mountPoint.count } }
            .sorted { $0.mountPoint == "/" || ($1.mountPoint != "/" && $0.mountPoint < $1.mountPoint) }
        metrics.containers = dockerAvailable ? containers : nil
        return metrics
    }

    private func numbers(_ value: String) -> [Double] {
        value.split(separator: " ").compactMap { Double($0) }
    }

    private func clampPercent(_ value: Double) -> Double { min(max(value, 0), 100) }
}
