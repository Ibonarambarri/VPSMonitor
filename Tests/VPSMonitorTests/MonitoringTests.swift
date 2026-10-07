import XCTest
@testable import VPSMonitor

final class AlertEngineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(cpu: Double = 10, disk: Double = 10, failures: Int = 0) -> AlertSnapshot {
        var metrics = ServerMetrics()
        metrics.cpuPercent = cpu
        metrics.totalMemoryBytes = 100
        metrics.usedMemoryBytes = 10
        metrics.disks = [DiskUsage(filesystem: "/dev/vda1", mountPoint: "/",
                                   usedBytes: Int64(disk), availableBytes: Int64(100 - disk), totalBytes: 100)]
        return AlertSnapshot(sshFailures: failures, sshError: failures > 0 ? "timeout" : nil,
                             metrics: failures > 0 ? nil : metrics)
    }

    func testHighCPUMustBeSustainedBeforeAlerting() {
        var engine = AlertEngine()
        XCTAssertTrue(engine.evaluate(snapshot(cpu: 97), now: start).isEmpty)
        XCTAssertTrue(engine.evaluate(snapshot(cpu: 97), now: start.addingTimeInterval(60)).isEmpty)
        // A short dip resets the timer.
        XCTAssertTrue(engine.evaluate(snapshot(cpu: 40), now: start.addingTimeInterval(90)).isEmpty)
        XCTAssertTrue(engine.evaluate(snapshot(cpu: 97), now: start.addingTimeInterval(120)).isEmpty)
        let fired = engine.evaluate(snapshot(cpu: 97), now: start.addingTimeInterval(120 + AlertEngine.sustainedLoadDuration))
        XCTAssertEqual(fired.map(\.id), ["metric.cpu"])
        XCTAssertEqual(engine.overallSeverity, .warning)
    }

    func testAlertClearsOnlyBelowHysteresis() {
        var engine = AlertEngine()
        _ = engine.evaluate(snapshot(disk: 90), now: start)
        XCTAssertEqual(engine.activeAlerts.map(\.id), ["metric.disk./"])
        // 82 % is under the 85 % threshold but within the hysteresis band.
        XCTAssertTrue(engine.evaluate(snapshot(disk: 82), now: start.addingTimeInterval(30)).isEmpty)
        let resolved = engine.evaluate(snapshot(disk: 70), now: start.addingTimeInterval(60))
        XCTAssertEqual(resolved.map(\.title), ["Resuelto: Disco / casi lleno"])
        XCTAssertNil(engine.overallSeverity)
    }

    func testServerDownNeedsTwoFailuresAndKeepsMetricAlerts() {
        var engine = AlertEngine()
        _ = engine.evaluate(snapshot(disk: 96), now: start)
        XCTAssertEqual(engine.overallSeverity, .critical)
        XCTAssertTrue(engine.evaluate(snapshot(failures: 1), now: start.addingTimeInterval(15)).isEmpty)
        let down = engine.evaluate(snapshot(failures: 2), now: start.addingTimeInterval(30))
        XCTAssertEqual(down.map(\.id), ["ssh.down"])
        XCTAssertEqual(Set(engine.activeAlerts.map(\.id)), ["ssh.down", "metric.disk./"])
        let recovered = engine.evaluate(snapshot(disk: 96), now: start.addingTimeInterval(45))
        XCTAssertEqual(recovered.map(\.title), ["Resuelto: Servidor sin respuesta"])
    }

    func testCoolifyResourceFailureAlerts() {
        var engine = AlertEngine()
        let resource = CoolifyResource(id: "r1", name: "API", type: "Aplicación", status: "exited", url: nil)
        let project = CoolifyProject(id: "p", name: "Web", environments: [CoolifyEnvironment(id: "e", name: "prod", resources: [resource])])
        let fired = engine.evaluate(AlertSnapshot(coolifyFailures: 0, projects: [project]), now: start)
        XCTAssertEqual(fired.first?.title, "API con problemas")
        // Coolify being unreachable keeps the known resource alert instead of resolving it.
        XCTAssertTrue(engine.evaluate(AlertSnapshot(coolifyFailures: 1, projects: nil), now: start.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(engine.activeAlerts.count, 1)
    }
}

final class MetricsHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func sample(_ offset: TimeInterval, cpu: Double? = 20) -> MetricSample {
        guard let cpu else { return MetricSample(date: start.addingTimeInterval(offset), metrics: nil) }
        var metrics = ServerMetrics()
        metrics.cpuPercent = cpu
        metrics.totalMemoryBytes = 100
        metrics.usedMemoryBytes = 50
        return MetricSample(date: start.addingTimeInterval(offset), metrics: metrics)
    }

    func testPersistsThinnedSamplesButKeepsOutages() {
        var history = MetricsHistory()
        for second in stride(from: 0.0, through: 60, by: 3) { history.append(sample(second)) }
        XCTAssertEqual(history.persisted.map { $0.date.timeIntervalSince(start) }, [0, 30, 60])
        XCTAssertEqual(history.recent.count, 21)
        history.append(sample(62, cpu: nil))
        XCTAssertEqual(history.persisted.last?.isReachable, false)
    }

    func testAvailabilityIsTimeWeightedAndIgnoresGaps() {
        var history = MetricsHistory()
        for minute in 0..<9 { history.append(sample(Double(minute) * 60)) }
        history.append(sample(540, cpu: nil))
        // The Mac slept for two hours: only the first minutes of that gap are counted.
        history.append(sample(540 + 7200))
        let availability = history.availability(now: start.addingTimeInterval(540 + 7200 + 60))
        XCTAssertEqual(availability ?? 0, 600.0 / (600 + 600) * 100, accuracy: 0.01)
    }

    func testSeriesSplitsLinesAtOutagesAndGaps() {
        var history = MetricsHistory()
        history.append(sample(0))
        history.append(sample(30))
        history.append(sample(60, cpu: nil))
        history.append(sample(90))
        history.append(sample(90 + 3600))
        let series = history.series(for: .day, now: start.addingTimeInterval(90 + 3600))
        XCTAssertEqual(series.outages.count, 1)
        XCTAssertEqual(Set(series.points.map(\.segment)).count, 2)
    }

    func testHistoryStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vpsmonitor-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MetricsHistoryStore(fileURL: url)
        store.save([sample(0), sample(30, cpu: nil)])
        let loaded = store.load(now: start.addingTimeInterval(60))
        XCTAssertEqual(loaded, [sample(0), sample(30, cpu: nil)])
        XCTAssertTrue(store.load(now: start.addingTimeInterval(MetricsHistory.retention + 120)).isEmpty)
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testPassesInputAndCollectsLargeOutput() async throws {
        let output = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-s"],
                                                 input: Data("yes x | head -n 200000; echo done >&2".utf8), timeout: 10)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout.count, 400_000)
        XCTAssertEqual(output.standardError, "done")
    }

    func testTimesOutHungCommands() async {
        let start = Date()
        do {
            _ = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5)
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertTrue(error is ProcessTimeoutError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
