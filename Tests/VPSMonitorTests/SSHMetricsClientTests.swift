import XCTest
@testable import VPSMonitor

final class SSHMetricsClientTests: XCTestCase {
    func testParsesLinuxMetrics() throws {
        let input = """
        PROC=101|160|8|my_worker
        PROC=0|329|1|sh
        STAT1=cpu  313 0 221 16179 53 0 83 7 0 0
        STAT2=cpu  414 0 222 16983 153 0 84 107 0 0
        NET1=1000 500
        NET2=2001000 1500
        CORES=10
        PAGESIZE=4096
        MEM=8388608 4194304 1048576 524288
        LOAD=0.80 0.60 0.40
        UPTIME=93784.50
        DISK=/dev/vda1|171798691840|75161927680|96636764160|/
        DISK=/dev/vda1|171798691840|75161927680|96636764160|/etc/hosts
        DISK=/dev/vdb|1000|900|100|/mnt/data volume
        REBOOT=1
        FAILED=backup.service
        DOCKER=1
        CTR=api|running|Up 2 hours (unhealthy)
        CTR=db|running|Up 3 days
        """
        let metrics = try SSHMetricsClient().parse(input)
        // 1107 ticks elapsed; 904 idle or iowait. Steal counts as busy time, as in top.
        XCTAssertEqual(metrics.cpuPercent, 203.0 / 1107 * 100, accuracy: 0.01)
        XCTAssertEqual(metrics.iowaitPercent, 100.0 / 1107 * 100, accuracy: 0.01)
        XCTAssertEqual(metrics.stealPercent, 100.0 / 1107 * 100, accuracy: 0.01)
        XCTAssertEqual(metrics.memoryPercent, 50, accuracy: 0.01)
        XCTAssertEqual(metrics.swapPercent, 50, accuracy: 0.01)
        XCTAssertEqual(metrics.load, [0.8, 0.6, 0.4])
        XCTAssertEqual(metrics.uptimeSeconds, 93784.5)
        XCTAssertEqual(metrics.networkReceiveRate, 2_000_000 / 1.107, accuracy: 1)
        XCTAssertEqual(metrics.disks.map(\.mountPoint), ["/", "/mnt/data volume"])
        XCTAssertEqual(metrics.rootDisk?.percent ?? 0, 43.75, accuracy: 0.01)
        XCTAssertEqual(metrics.fullestDisk?.mountPoint, "/mnt/data volume")
        XCTAssertEqual(metrics.processes.first?.name, "my_worker")
        XCTAssertEqual(metrics.processes.first?.memoryBytes, 160 * 4096)
        XCTAssertTrue(metrics.rebootRequired)
        XCTAssertEqual(metrics.failedUnits, ["backup.service"])
        XCTAssertEqual(metrics.containers?.map(\.health), [.critical, .healthy])
    }

    func testDockerIsUnavailableWithoutMarker() throws {
        let input = "STAT1=cpu 1 0 1 10\nSTAT2=cpu 2 0 2 20\nMEM=1024 512 0 0\n"
        XCTAssertNil(try SSHMetricsClient().parse(input).containers)
        XCTAssertThrowsError(try SSHMetricsClient().parse("MEM=1024 512 0 0\n"))
    }

    func testUnhealthyRunningResourceIsCritical() {
        let resource = CoolifyResource(id: "app", name: "App", type: "Aplicación", status: "running:unhealthy", url: nil)
        XCTAssertEqual(resource.health, .critical)
    }

    func testGroupsCoolifyInventoryByEnvironment() {
        let project: JSONValue = .object([
            "uuid": .string("project-1"),
            "name": .string("Proyecto"),
            "environments": .array([
                .object(["id": .number(7), "uuid": .string("env-1"), "name": .string("production")])
            ])
        ])
        let application: JSONValue = .object([
            "uuid": .string("app-1"), "name": .string("API"), "status": .string("running:healthy"),
            "environment_id": .number(7), "fqdn": .string("https://api.example.com")
        ])

        let projects = CoolifyClient().parseProjects(details: [project], summaries: [project], applications: [application], services: [], databases: [])

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].environments[0].resources.map(\.name), ["API"])
        XCTAssertEqual(projects[0].health, .healthy)
    }

    func testBuildsInteractiveSSHCommandWithSeparateArguments() throws {
        var configuration = MonitorConfiguration()
        configuration.sshHost = "server.example.com"
        configuration.sshUser = "deploy"
        configuration.sshPort = "2222"
        configuration.sshKeyPath = "~/Keys/server key's_ed25519"

        let command = try SSHCommandBuilder().build(configuration: configuration)

        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertEqual(command.arguments, [
            "-p", "2222", "-o", "IdentitiesOnly=yes", "-i",
            NSString(string: "~/Keys/server key's_ed25519").expandingTildeInPath,
            "--", "deploy@server.example.com"
        ])
        XCTAssertEqual(SSHLaunchCommand.shellQuote("server key's_ed25519"), "'server key'\\''s_ed25519'")
    }

    func testEmptyKeyOmitsIdentityArguments() throws {
        var configuration = MonitorConfiguration()
        configuration.sshHost = "2001:db8::1"
        configuration.sshKeyPath = ""

        let command = try SSHCommandBuilder().build(configuration: configuration)

        XCTAssertEqual(command.arguments, ["-p", "22", "--", "root@2001:db8::1"])
    }

    func testWarpUsesRecognizableSSHCommandWithoutOptionTerminator() {
        let command = SSHLaunchCommand(
            executable: "/usr/bin/ssh",
            arguments: [
                "-p", "22", "-o", "IdentitiesOnly=yes", "-i", "/tmp/key with space's",
                "--", "root@server.example.com"
            ]
        )

        XCTAssertEqual(
            command.warpShellCommand,
            "ssh -p 22 -o IdentitiesOnly=yes -i '/tmp/key with space'\\''s' root@server.example.com"
        )
        XCTAssertFalse(command.warpShellCommand.contains("/usr/bin/ssh"))
        XCTAssertFalse(command.warpShellCommand.contains(" -- "))
    }

    func testWarpQuotesUnsafeArgumentAsOneShellWord() {
        let command = SSHLaunchCommand(
            executable: "/usr/bin/ssh",
            arguments: ["-p", "22", "--", "root@server.example.com;touch /tmp/not-run"]
        )

        XCTAssertEqual(
            command.warpShellCommand,
            "ssh -p 22 'root@server.example.com;touch /tmp/not-run'"
        )
    }

    func testRejectsInvalidPorts() {
        for port in ["", "abc", "0", "65536"] {
            var configuration = MonitorConfiguration()
            configuration.sshHost = "server.example.com"
            configuration.sshPort = port
            XCTAssertThrowsError(try SSHCommandBuilder().build(configuration: configuration))
        }
    }

    func testRejectsShellPayloadsInHostAndUser() {
        for host in ["server;touch /tmp/pwned", "$(whoami)", "`id`", "server\nother"] {
            var configuration = MonitorConfiguration()
            configuration.sshHost = host
            XCTAssertThrowsError(try SSHCommandBuilder().build(configuration: configuration))
        }

        var configuration = MonitorConfiguration()
        configuration.sshHost = "server.example.com"
        configuration.sshUser = "-oProxyCommand=id"
        XCTAssertThrowsError(try SSHCommandBuilder().build(configuration: configuration))
    }

    func testConfigurationStorePersistsTerminalSettings() throws {
        let suiteName = "VPSMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var configuration = MonitorConfiguration()
        configuration.sshHost = "server.example.com"
        configuration.sshTerminal = .custom
        configuration.customTerminalExecutable = "/usr/bin/open"
        configuration.customTerminalArguments = "-a\nGhostty\n--args\n-e\n{ssh}"

        ConfigurationStore(defaults: defaults).save(configuration)
        let loaded = ConfigurationStore(defaults: defaults).load()

        XCTAssertEqual(loaded.sshHost, "server.example.com")
        XCTAssertEqual(loaded.sshTerminal, .custom)
        XCTAssertEqual(loaded.customTerminalExecutable, "/usr/bin/open")
        XCTAssertEqual(loaded.customTerminalArguments, configuration.customTerminalArguments)
    }

    func testConfigurationStoreUsesSafeTerminalFallback() throws {
        let suiteName = "VPSMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("terminal-that-no-longer-exists", forKey: "sshTerminal")

        XCTAssertEqual(ConfigurationStore(defaults: defaults).load().sshTerminal, .appleTerminal)
    }

    func testCustomTerminalExpandsSSHAsSeparateArguments() throws {
        var configuration = MonitorConfiguration()
        configuration.customTerminalExecutable = "/usr/bin/open"
        configuration.customTerminalArguments = "-a\nGhostty; touch /tmp/not-run\n--args\n-e\n{ssh}"
        let ssh = SSHLaunchCommand(executable: "/usr/bin/ssh", arguments: ["-p", "22", "--", "root@example.com"])

        let invocation = try SSHSessionLauncher().customInvocation(for: ssh, configuration: configuration)

        XCTAssertEqual(invocation.executable, "/usr/bin/open")
        XCTAssertEqual(invocation.arguments, [
            "-a", "Ghostty; touch /tmp/not-run", "--args", "-e",
            "/usr/bin/ssh", "-p", "22", "--", "root@example.com"
        ])
    }

    func testCustomTerminalRequiresStandaloneSSHPlaceholder() {
        var configuration = MonitorConfiguration()
        configuration.customTerminalExecutable = "/usr/bin/open"
        configuration.customTerminalArguments = "--args={ssh}"
        let ssh = SSHLaunchCommand(executable: "/usr/bin/ssh", arguments: [])

        XCTAssertThrowsError(try SSHSessionLauncher().customInvocation(for: ssh, configuration: configuration))
    }

    func testCustomTerminalRejectsDuplicateSSHPlaceholder() {
        var configuration = MonitorConfiguration()
        configuration.customTerminalExecutable = "/usr/bin/open"
        configuration.customTerminalArguments = "{ssh}\n{ssh}"
        let ssh = SSHLaunchCommand(executable: "/usr/bin/ssh", arguments: [])

        XCTAssertThrowsError(try SSHSessionLauncher().customInvocation(for: ssh, configuration: configuration))
    }

    func testMetricsSSHCommandUsesValidatedDestinationAfterOptionTerminator() throws {
        var configuration = MonitorConfiguration()
        configuration.sshHost = "server.example.com"
        configuration.sshUser = "monitor"
        configuration.sshKeyPath = ""

        let command = try SSHMetricsClient().metricsCommand(configuration: configuration, remoteCommand: "uptime")

        XCTAssertEqual(Array(command.arguments.prefix(8)), [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"
        ])
        XCTAssertEqual(Array(command.arguments.suffix(5)), ["-p", "22", "--", "monitor@server.example.com", "uptime"])
        XCTAssertTrue(command.arguments.contains("ControlMaster=auto"))
        XCTAssertEqual(command.arguments.last, "uptime")

        configuration.sshUser = "-oProxyCommand=id"
        XCTAssertThrowsError(try SSHMetricsClient().metricsCommand(configuration: configuration, remoteCommand: "uptime"))
    }

    func testLiveCoolifyWhenProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["VPSMONITOR_TEST_COOLIFY_TOKEN"],
              let baseURL = environment["VPSMONITOR_TEST_COOLIFY_URL"] else {
            throw XCTSkip("Credenciales de Coolify no configuradas")
        }

        let projects = try await CoolifyClient().fetchProjects(baseURL: baseURL, token: token)
        XCTAssertFalse(projects.isEmpty)
        XCTAssertFalse(projects.flatMap(\.resources).isEmpty)
    }

    func testLiveSSHMetricsWhenProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sshHost = environment["VPSMONITOR_TEST_SSH_HOST"],
              let sshKey = environment["VPSMONITOR_TEST_SSH_KEY"] else {
            throw XCTSkip("Servidor SSH de integración no configurado")
        }

        var configuration = MonitorConfiguration()
        configuration.sshHost = sshHost
        configuration.sshUser = environment["VPSMONITOR_TEST_SSH_USER"] ?? "root"
        configuration.sshPort = environment["VPSMONITOR_TEST_SSH_PORT"] ?? "22"
        configuration.sshKeyPath = sshKey
        let client = SSHMetricsClient()
        let metrics = try await client.fetch(configuration: configuration)
        XCTAssertGreaterThan(metrics.totalMemoryBytes, 0)
        XCTAssertGreaterThan(metrics.cores, 0)
        XCTAssertGreaterThan(metrics.uptimeSeconds, 0)

        // The second check reuses the shared connection, so it costs little more than the 1 s sample.
        let start = Date()
        _ = try await client.fetch(configuration: configuration)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        await client.resetConnection(configuration: configuration)
    }
}
