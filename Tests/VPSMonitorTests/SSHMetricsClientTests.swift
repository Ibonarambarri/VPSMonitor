import XCTest
@testable import VPSMonitor

final class SSHMetricsClientTests: XCTestCase {
    func testParsesLinuxMetrics() throws {
        let input = "CPU=37.5\nMEM=4294967296,8589934592\nDISK=75161927680,171798691840\nLOAD=0.80 0.60 0.40\nUPTIME=up 18 days\n"
        let metrics = try SSHMetricsClient().parse(input)
        XCTAssertEqual(metrics.cpuPercent, 37.5)
        XCTAssertEqual(metrics.memoryPercent, 50, accuracy: 0.01)
        XCTAssertEqual(metrics.diskPercent, 43.75, accuracy: 0.01)
        XCTAssertEqual(metrics.uptime, "18 days")
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

        XCTAssertEqual(command.arguments, [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-p", "22", "--", "monitor@server.example.com", "uptime"
        ])

        configuration.sshUser = "-oProxyCommand=id"
        XCTAssertThrowsError(try SSHMetricsClient().metricsCommand(configuration: configuration, remoteCommand: "uptime"))
    }

    func testLiveConfigurationWhenProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["VPSMONITOR_TEST_COOLIFY_TOKEN"],
              let baseURL = environment["VPSMONITOR_TEST_COOLIFY_URL"],
              let sshHost = environment["VPSMONITOR_TEST_SSH_HOST"],
              let sshKey = environment["VPSMONITOR_TEST_SSH_KEY"] else {
            throw XCTSkip("Credenciales de integración no configuradas")
        }

        let projects = try await CoolifyClient().fetchProjects(baseURL: baseURL, token: token)
        XCTAssertFalse(projects.isEmpty)
        XCTAssertFalse(projects.flatMap(\.resources).isEmpty)

        let configuration = MonitorConfiguration(coolifyURL: baseURL,
                                                 sshHost: sshHost,
                                                 sshUser: "root",
                                                 sshPort: "22",
                                                 sshKeyPath: sshKey,
                                                 refreshInterval: 30,
                                                 sshTerminal: .appleTerminal,
                                                 customTerminalExecutable: "",
                                                 customTerminalArguments: "")
        let metrics = try await SSHMetricsClient().fetch(configuration: configuration)
        XCTAssertGreaterThan(metrics.totalMemoryBytes, 0)
        XCTAssertGreaterThan(metrics.totalDiskBytes, 0)
    }
}
