import Foundation
@testable import MacMonitor

func makeSignals(
    id: String = "g", name: String = "next-server", idle: TimeInterval = 7200,
    footprint: UInt64 = 1_000_000_000, orphan: Bool = true
) -> UsageSignals {
    UsageSignals(
        groupID: id, displayName: name, kind: .cli, executablePath: "/usr/bin/node",
        arguments: ["next", "dev"], cwd: nil, ports: [3110], establishedConnections: 0,
        processCount: 3, sameNameMaxCount: 3, uptimeSeconds: 86400, idleSeconds: idle,
        isOrphan: orphan, lostAncestor: "claude", footprint: footprint,
        footprintGrowthPercent: nil, footprintMonotonic: false, cpuPercent: 0
    )
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

/// 호출 횟수와 모드를 기록하는 가짜 엔진
final class FakeEngine: VerdictEngine, @unchecked Sendable {
    let id = "fake"
    let displayName = "Fake"
    private let lock = NSLock()
    private var _calls: [(mode: VerdictMode, apiKey: String, state: String)] = []
    var reply: @Sendable (VerdictMode) -> Result<EngineReply, EngineFailure> = { mode in
        .success(FakeEngine.reply(mode: mode))
    }

    var calls: [(mode: VerdictMode, apiKey: String, state: String)] { lock.withLock { _calls } }

    static func reply(mode: VerdictMode, verdict: VerdictChoice = .terminate, confidence: Double = 0.9, loss: Double = 0.1) -> EngineReply {
        EngineReply(
            verdict: mode == .full ? verdict : nil, confidence: mode == .full ? confidence : nil,
            probabilities: [verdict.rawValue: confidence], dataLossProbability: loss,
            inputTokens: 700, outputTokens: 60, model: "fake-1", requestBody: "{\"req\":1}", responseBody: "{\"res\":1}", httpStatus: 200
        )
    }

    func judge(state: String, mode: VerdictMode, apiKey: String) async throws -> EngineReply {
        lock.withLock { _calls.append((mode, apiKey, state)) }
        switch reply(mode) {
        case .success(let r): return r
        case .failure(let f): throw f
        }
    }

    func validate(apiKey: String) async -> Bool { true }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mm-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
