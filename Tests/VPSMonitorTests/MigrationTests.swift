import XCTest
@testable import VPSMonitor

/// Installed copies of 1.1 and 1.2 must keep every setting after updating.
final class MigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "VPSMonitorMigrationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Same shape as the `vpsProfiles` value written by version 1.2.6.
    private let version12Profiles = """
    [{"id":"FCAA04A0-E5B1-49EA-BB99-E20EEEB48934","name":"Personal","configuration":{"customTerminalExecutable":"","sshUser":"root","sshKeyPath":"~/.ssh/personal","coolifyURL":"https://coolify.example.com","sshPort":"22","sshTerminal":"warp","refreshInterval":60,"customTerminalArguments":"","sshHost":"personal.example.com"}},
     {"id":"584622DD-CDD2-447A-A4F1-2FE408257B32","name":"Alpify","configuration":{"customTerminalExecutable":"","sshKeyPath":"~/.ssh/alpify","sshUser":"vpsmonitor","coolifyURL":"https://deploy.example.com","sshPort":"22","sshTerminal":"warp","refreshInterval":60,"customTerminalArguments":"","sshHost":"alpify.example.com"}}]
    """

    func testReadsVersion12Profiles() throws {
        defaults.set(Data(version12Profiles.utf8), forKey: "vpsProfiles")
        defaults.set("584622DD-CDD2-447A-A4F1-2FE408257B32", forKey: "selectedVPSProfileID")
        defaults.set(60.0, forKey: "refreshInterval")
        let store = ConfigurationStore(defaults: defaults)

        let profiles = store.loadProfiles()
        XCTAssertEqual(profiles.map(\.name), ["Personal", "Alpify"])
        XCTAssertEqual(profiles[1].configuration.sshUser, "vpsmonitor")
        XCTAssertEqual(profiles[1].configuration.sshTerminal, .warp)
        XCTAssertEqual(store.loadSelectedProfileID(), profiles[1].id)
        XCTAssertEqual(store.loadPreferences().refreshInterval, 60)
        XCTAssertEqual(KeychainStore.account(for: profiles[0].id), "coolify-token-fcaa04a0-e5b1-49ea-bb99-e20eeeb48934")
    }

    func testSavedProfilesStayReadableByVersion12() throws {
        defaults.set(Data(version12Profiles.utf8), forKey: "vpsProfiles")
        let store = ConfigurationStore(defaults: defaults)
        store.saveProfiles(store.loadProfiles())

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "vpsProfiles"))) as? [[String: Any]])
        XCTAssertEqual(json.first?["id"] as? String, "FCAA04A0-E5B1-49EA-BB99-E20EEEB48934")
        let configuration = try XCTUnwrap(json.first?["configuration"] as? [String: Any])
        // Version 1.2 decodes every one of these keys.
        for key in ["sshHost", "sshUser", "sshPort", "sshKeyPath", "coolifyURL", "sshTerminal",
                    "customTerminalExecutable", "customTerminalArguments", "refreshInterval"] {
            XCTAssertNotNil(configuration[key], key)
        }
    }

    func testMigratesVersion11SingleServer() {
        defaults.set("legacy.example.com", forKey: "sshHost")
        defaults.set("deploy", forKey: "sshUser")
        defaults.set("https://coolify.example.com", forKey: "coolifyURL")
        let profiles = ConfigurationStore(defaults: defaults).loadProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id, ConfigurationStore.legacyProfileID)
        XCTAssertEqual(profiles[0].configuration.sshHost, "legacy.example.com")
        XCTAssertEqual(profiles[0].configuration.sshUser, "deploy")
    }

    func testImportsVersion12ChartSamples() throws {
        let id = UUID(uuidString: "FCAA04A0-E5B1-49EA-BB99-E20EEEB48934")!
        let samples = #"[{"memory":58.7,"id":"C324F830-7DDA-4C5B-B298-947245EC1CD0","date":813064747.17,"cpu":32.6},{"id":"EF9BD789-BCF5-479D-84AC-E3D522C2A5E2","date":813064816.14}]"#
        defaults.set(Data(samples.utf8), forKey: "metricSamples.fcaa04a0-e5b1-49ea-bb99-e20eeeb48934")
        let imported = ConfigurationStore(defaults: defaults).legacySamples(for: id)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported[0].cpu, 32.6)
        XCTAssertEqual(imported[0].date, Date(timeIntervalSinceReferenceDate: 813064747.17))
        XCTAssertFalse(imported[1].isReachable)
    }

    func testInvalidStoredProfilesFallBackToOneServer() {
        defaults.set(Data("not json".utf8), forKey: "vpsProfiles")
        XCTAssertEqual(ConfigurationStore(defaults: defaults).loadProfiles().count, 1)
    }

    func testPreferencesRoundTrip() {
        let store = ConfigurationStore(defaults: defaults)
        var preferences = MonitorPreferences()
        preferences.refreshInterval = 10
        preferences.showCPUInMenuBar = true
        preferences.diskAlertThreshold = 95
        store.savePreferences(preferences)
        XCTAssertEqual(store.loadPreferences(), preferences)
    }

    @MainActor
    func testViewModelManagesSeveralServers() throws {
        defaults.set(Data(version12Profiles.utf8), forKey: "vpsProfiles")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(defaults: defaults,
                                     historyStoreProvider: { MetricsHistoryStore(fileURL: directory.appendingPathComponent("\($0).json")) },
                                     usesKeychain: false)
        defer { model.monitors.values.forEach { $0.stop() } }
        XCTAssertEqual(model.orderedMonitors.map(\.profile.name), ["Personal", "Alpify"])

        var profiles = model.profiles
        profiles.removeFirst()
        let added = VPSProfile(name: "Nuevo")
        profiles.append(added)
        model.save(profiles: profiles, tokens: [:], selectedID: added.id, preferences: model.preferences)

        XCTAssertEqual(model.orderedMonitors.map(\.profile.name), ["Alpify", "Nuevo"])
        XCTAssertEqual(model.selectedProfileID, added.id)
        XCTAssertEqual(ConfigurationStore(defaults: defaults).loadProfiles().map(\.name), ["Alpify", "Nuevo"])
        XCTAssertEqual(ConfigurationStore(defaults: defaults).loadSelectedProfileID(), added.id)
    }
}
