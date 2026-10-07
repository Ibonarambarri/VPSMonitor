import Foundation

/// One check of the server. Metric values are `nil` when the server did not answer.
struct MetricSample: Codable, Equatable {
    let date: Date
    let cpu: Double?
    let memory: Double?
    let receiveRate: Double?
    let transmitRate: Double?

    var isReachable: Bool { cpu != nil }

    init(date: Date, cpu: Double?, memory: Double?, receiveRate: Double? = nil, transmitRate: Double? = nil) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.receiveRate = receiveRate
        self.transmitRate = transmitRate
    }

    init(date: Date, metrics: ServerMetrics?) {
        self.date = date
        cpu = metrics?.cpuPercent
        memory = metrics?.memoryPercent
        receiveRate = metrics?.networkReceiveRate
        transmitRate = metrics?.networkTransmitRate
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case live, hour, sixHours, day

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .live: 10 * 60
        case .hour: 3600
        case .sixHours: 6 * 3600
        case .day: 24 * 3600
        }
    }

    var shortName: String {
        switch self {
        case .live: "10 min"
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        }
    }
}

/// A point ready to draw. Points with the same `segment` are joined by a line;
/// a new segment starts after a gap or an outage.
struct ChartPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let segment: Int
    let cpu: Double?
    let memory: Double?
    let receiveRate: Double?
    let transmitRate: Double?
}

struct ChartSeries {
    var points: [ChartPoint] = []
    var outages: [Date] = []
}

/// Keeps every sample from the last minutes for the live chart and a 24 h history,
/// thinned to one sample every 30 s, that survives restarts.
struct MetricsHistory {
    static let retention: TimeInterval = 24 * 3600
    static let persistedSpacing: TimeInterval = 30
    /// Gaps longer than this (Mac asleep, app closed) are neither drawn nor counted.
    static let maximumGap: TimeInterval = 10 * 60

    private(set) var recent: [MetricSample] = []
    private(set) var persisted: [MetricSample] = []

    init(persisted: [MetricSample] = []) {
        self.persisted = persisted.sorted { $0.date < $1.date }
    }

    mutating func append(_ sample: MetricSample) {
        recent.append(sample)
        recent.removeAll { sample.date.timeIntervalSince($0.date) > HistoryRange.live.duration }

        if let last = persisted.last,
           sample.date.timeIntervalSince(last.date) < Self.persistedSpacing,
           last.isReachable == sample.isReachable {
            return
        }
        persisted.append(sample)
        persisted.removeAll { sample.date.timeIntervalSince($0.date) > Self.retention }
    }

    /// Share of observed time in which the server answered, ignoring periods without observations.
    func availability(over duration: TimeInterval = retention, now: Date = Date()) -> Double? {
        let samples = persisted.filter { now.timeIntervalSince($0.date) <= duration }
        guard !samples.isEmpty else { return nil }
        var up = 0.0, observed = 0.0
        for (index, sample) in samples.enumerated() {
            let next = index + 1 < samples.count ? samples[index + 1].date : now
            let weight = min(max(next.timeIntervalSince(sample.date), 1), Self.maximumGap)
            observed += weight
            if sample.isReachable { up += weight }
        }
        return observed > 0 ? up / observed * 100 : nil
    }

    func series(for range: HistoryRange, now: Date = Date(), maximumPoints: Int = 120) -> ChartSeries {
        let source = range == .live ? recent : persisted + recent.filter { $0.date > (persisted.last?.date ?? .distantPast) }
        let samples = source.filter { now.timeIntervalSince($0.date) <= range.duration }
        guard !samples.isEmpty else { return ChartSeries() }

        let bucketSize = max(range.duration / Double(maximumPoints), 0)
        let buckets: [[MetricSample]]
        if range == .live || bucketSize <= Self.persistedSpacing {
            buckets = samples.map { [$0] }
        } else {
            buckets = Dictionary(grouping: samples) { Int($0.date.timeIntervalSince1970 / bucketSize) }
                .sorted { $0.key < $1.key }.map(\.value)
        }

        var result = ChartSeries()
        var segment = 0
        var previousDate: Date?
        let gapLimit = max(bucketSize * 2.5, Self.maximumGap)
        for bucket in buckets {
            let reachable = bucket.filter(\.isReachable)
            // Even a brief outage inside a wide bucket is marked and breaks the line.
            if let outage = bucket.first(where: { !$0.isReachable }) {
                result.outages.append(outage.date)
                segment += 1
                previousDate = nil
            }
            guard !reachable.isEmpty else { continue }
            let date = reachable[reachable.count / 2].date
            if let previousDate, date.timeIntervalSince(previousDate) > gapLimit { segment += 1 }
            func average(_ keyPath: KeyPath<MetricSample, Double?>) -> Double? {
                let values = reachable.compactMap { $0[keyPath: keyPath] }
                return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            }
            result.points.append(ChartPoint(date: date, segment: segment,
                                            cpu: average(\.cpu), memory: average(\.memory),
                                            receiveRate: average(\.receiveRate), transmitRate: average(\.transmitRate)))
            previousDate = date
        }
        return result
    }
}

struct MetricsHistoryStore {
    let fileURL: URL

    static func standard(for profileID: UUID) -> MetricsHistoryStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MetricsHistoryStore(fileURL: support.appendingPathComponent("VPSMonitor", isDirectory: true)
            .appendingPathComponent("history-\(profileID.uuidString.lowercased()).json"))
    }

    var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    func load(now: Date = Date()) -> [MetricSample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? Self.decoder.decode([MetricSample].self, from: data) else { return [] }
        return samples.filter { now.timeIntervalSince($0.date) <= MetricsHistory.retention }
    }

    func save(_ samples: [MetricSample]) {
        guard let data = try? Self.encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() { try? FileManager.default.removeItem(at: fileURL) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
