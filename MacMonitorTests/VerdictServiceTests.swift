import Foundation
import Testing
@testable import MacMonitor

struct VerdictServiceTests {
    private func make(_ engine: FakeEngine, key: String? = "SECRET-KEY-123", clock: TestClock = TestClock()) -> (VerdictService, VerdictAuditLog, URL) {
        let dir = tempDirectory()
        let audit = VerdictAuditLog(directory: dir, now: { clock.now })
        let store = MemoryKeyStore(key.map { ["fake": $0] } ?? [:])
        return (VerdictService(engines: [engine], keyStore: store, audit: audit, now: { clock.now }), audit, dir)
    }

    private let amb = RuleOutcome.ambiguous(reason: "r")
    private let term = RuleOutcome.tag(.terminate, reason: "r")

    @Test func disabledOrNoKeyNeverCallsEngine() async {
        let engine = FakeEngine()
        let (svc, _, _) = make(engine)
        #expect(await svc.verdicts(for: [(makeSignals(), amb)], enabled: false, engineID: "fake").isEmpty)
        let (noKey, _, _) = make(engine, key: nil)
        #expect(await noKey.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "fake").isEmpty)
        #expect(await svc.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "unknown").isEmpty)
        #expect(engine.calls.isEmpty)
    }

    @Test func modeFollowsRule() async {
        let engine = FakeEngine()
        let (svc, _, _) = make(engine)
        let items = [(makeSignals(id: "a"), amb), (makeSignals(id: "b"), term), (makeSignals(id: "c"), RuleOutcome.none), (makeSignals(id: "d"), RuleOutcome.tag(.attention, reason: "r"))]
        let out = await svc.verdicts(for: items, enabled: true, engineID: "fake")
        #expect(Set(out.keys) == ["a", "b"])
        #expect(engine.calls.count == 2)
        #expect(out["a"]?.choice == .terminate && out["a"]?.status == .ok)
        #expect(out["b"]?.choice == nil && out["b"]?.dataLossProbability == 0.1)
        #expect(Set(engine.calls.map(\.mode)) == [.full, .dataLossOnly])
        #expect(engine.calls.allSatisfy { $0.apiKey == "SECRET-KEY-123" })
    }

    @Test func lowConfidenceIsAmbiguous() async {
        let engine = FakeEngine()
        engine.reply = { .success(FakeEngine.reply(mode: $0, verdict: .attention, confidence: 0.38)) }
        let (svc, _, _) = make(engine)
        let out = await svc.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "fake")
        #expect(out["g"]?.status == .ambiguous)
    }

    @Test func cacheHitWithinFiveMinutes() async {
        let engine = FakeEngine(); let clock = TestClock()
        let (svc, _, _) = make(engine, clock: clock)
        _ = await svc.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "fake")
        clock.advance(299)
        let hit = await svc.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "fake")
        #expect(hit["g"] != nil)
        #expect(engine.calls.count == 1)
        clock.advance(2)
        _ = await svc.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "fake")
        #expect(engine.calls.count == 2)
    }

    @Test func cacheInvalidatesOnIdleChangeAndFootprintDoubling() async {
        let engine = FakeEngine()
        let (svc, _, _) = make(engine)
        _ = await svc.verdicts(for: [(makeSignals(idle: 7200, footprint: 1000), amb)], enabled: true, engineID: "fake")
        _ = await svc.verdicts(for: [(makeSignals(idle: 9000, footprint: 1999), amb)], enabled: true, engineID: "fake")
        #expect(engine.calls.count == 1)
        _ = await svc.verdicts(for: [(makeSignals(idle: 0, footprint: 1000), amb)], enabled: true, engineID: "fake")
        #expect(engine.calls.count == 2)
        _ = await svc.verdicts(for: [(makeSignals(idle: 0, footprint: 2000), amb)], enabled: true, engineID: "fake")
        #expect(engine.calls.count == 3)
    }

    @Test func modeChangeInvalidatesCache() async {
        let engine = FakeEngine()
        let (svc, _, _) = make(engine)
        _ = await svc.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "fake")
        _ = await svc.verdicts(for: [(makeSignals(), term)], enabled: true, engineID: "fake")
        #expect(engine.calls.count == 2)
    }

    @Test func hourlyLimitSkipsAndLogs() async {
        let engine = FakeEngine(); let clock = TestClock()
        let (svc, audit, _) = make(engine, clock: clock)
        let items = (0..<302).map { (makeSignals(id: "g\($0)"), amb) }
        let out = await svc.verdicts(for: items, enabled: true, engineID: "fake")
        #expect(engine.calls.count == 300)
        #expect(out.count == 300)
        let skipped = await audit.recent(limit: 1000).filter(\.isSkipped)
        #expect(skipped.count == 2)
        // 한 시간 뒤에는 다시 호출한다
        clock.advance(3601)
        _ = await svc.verdicts(for: [(makeSignals(id: "new"), amb)], enabled: true, engineID: "fake")
        #expect(engine.calls.count == 301)
    }

    @Test func failureIsReportedLoggedAndNotCached() async {
        let engine = FakeEngine()
        engine.reply = { _ in .failure(EngineFailure(message: "HTTP 500 SECRET-KEY-123", requestBody: "{}", responseBody: "oops", httpStatus: 500)) }
        let (svc, audit, dir) = make(engine)
        let out = await svc.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "fake")
        guard case .failed = out["g"]?.status else { Issue.record("failed 아님"); return }
        _ = await svc.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "fake")
        #expect(engine.calls.count == 2)
        let entry = await audit.recent(limit: 1)[0]
        #expect(entry.isFailure && entry.httpStatus == 500 && entry.result == "판단 실패")
        let file = (try? String(contentsOf: dir.appendingPathComponent("ai-verdict-audit.jsonl"), encoding: .utf8)) ?? ""
        #expect(!file.contains("SECRET-KEY-123"))
    }

    @Test func successIsLoggedWithFinalResult() async {
        let engine = FakeEngine()
        let (svc, audit, _) = make(engine)
        _ = await svc.verdicts(for: [(makeSignals(), amb)], enabled: true, engineID: "fake")
        let entry = await audit.recent(limit: 1)[0]
        #expect(entry.engineID == "fake" && entry.model == "fake-1" && entry.mode == .full)
        #expect(entry.inputTokens == 700 && entry.result == "종료 추천 · 종료 추천 90%")
        #expect(entry.requestBody == "{\"req\":1}" && entry.responseBody == "{\"res\":1}")
    }
}
