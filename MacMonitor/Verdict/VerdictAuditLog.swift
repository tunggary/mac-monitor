import Foundation

/// 호출 1회의 기록 (jsonl 한 줄). API 키는 어느 필드에도 들어가지 않는다.
struct VerdictAuditEntry: Codable, Sendable, Equatable, Identifiable {
    static let skippedRateLimit = "skipped_rate_limit"

    var id: UUID = UUID()
    var time: Date
    var engineID: String
    var model: String?
    var groupID: String
    var groupName: String
    var mode: VerdictMode
    /// 가린 뒤에 실제로 보낸 요청 본문
    var requestBody: String?
    var responseBody: String?
    var httpStatus: Int?
    var latencyMs: Int
    var inputTokens: Int
    var outputTokens: Int
    /// 최종 적용 결과 ("종료 추천 · …", "태그 없음 · 판단 애매 …", "skipped_rate_limit" 등)
    var result: String
    var confidence: Double?
    var error: String?

    var isSkipped: Bool { result == Self.skippedRateLimit }
    var isFailure: Bool { error != nil }
}

struct AuditMonthSummary: Sendable, Equatable {
    var calls: Int
    var inputTokens: Int
    var estimatedCostUSD: Double
    var failures: Int
}

/// `~/Library/Application Support/MacMonitor/ai-verdict-audit.jsonl`
actor VerdictAuditLog {
    /// 입력 $0.042 / 1M 토큰 (출력은 무료)
    static let usdPerInputToken = 0.042 / 1_000_000
    static let retentionDays = 30
    static let maxBytes = 5 * 1024 * 1024

    nonisolated let fileURL: URL
    private let retention: TimeInterval
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private var lastPrune: Date?

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMonitor", isDirectory: true)
    }

    init(
        directory: URL = VerdictAuditLog.defaultDirectory(),
        retentionDays: Int = VerdictAuditLog.retentionDays,
        maxBytes: Int = VerdictAuditLog.maxBytes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        fileURL = directory.appendingPathComponent("ai-verdict-audit.jsonl")
        retention = TimeInterval(retentionDays) * 86_400
        self.maxBytes = maxBytes
        self.now = now
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func append(_ entry: VerdictAuditEntry) {
        guard let line = try? Self.encoder().encode(entry) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data("\n".utf8))
        pruneIfDue()
    }

    /// 최신순. `failuresOnly` 면 오류가 있는 호출만.
    func recent(limit: Int, failuresOnly: Bool = false) -> [VerdictAuditEntry] {
        let all = entries().reversed()
        return Array((failuresOnly ? all.filter(\.isFailure) : Array(all)).prefix(limit))
    }

    /// 이번 달 요약. 상한 초과로 건너뛴 줄은 호출 수에 넣지 않는다.
    func monthSummary(at date: Date? = nil, calendar: Calendar = .current) -> AuditMonthSummary {
        let date = date ?? now()
        let month = entries().filter { !$0.isSkipped && calendar.isDate($0.time, equalTo: date, toGranularity: .month) }
        let tokens = month.reduce(0) { $0 + $1.inputTokens }
        return AuditMonthSummary(
            calls: month.count, inputTokens: tokens,
            estimatedCostUSD: Double(tokens) * Self.usdPerInputToken,
            failures: month.filter(\.isFailure).count
        )
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        lastPrune = nil
    }

    /// 마지막 정리 후 하루가 지났을 때만 정리한다 (시작 시 첫 호출은 항상 정리).
    func pruneIfDue() {
        if let lastPrune, now().timeIntervalSince(lastPrune) < 86_400 { return }
        prune()
    }

    /// 30일 지난 줄을 지우고, 5MB 를 넘으면 오래된 줄부터 더 지운다.
    func prune() {
        let current = now()
        lastPrune = current
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = Self.decoder()
        var kept: [Data] = data.split(separator: UInt8(ascii: "\n")).map(Data.init).filter {
            guard let entry = try? decoder.decode(VerdictAuditEntry.self, from: $0) else { return false }
            return current.timeIntervalSince(entry.time) <= retention
        }
        var size = kept.reduce(0) { $0 + $1.count + 1 }
        while size > maxBytes, !kept.isEmpty {
            size -= kept.removeFirst().count + 1
        }
        guard kept.count != data.split(separator: UInt8(ascii: "\n")).count else { return }
        let joined = kept.reduce(into: Data()) { $0 += $1; $0 += Data("\n".utf8) }
        try? joined.write(to: fileURL, options: .atomic)
    }

    private func entries() -> [VerdictAuditEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = Self.decoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(VerdictAuditEntry.self, from: Data($0)) }
    }
}
