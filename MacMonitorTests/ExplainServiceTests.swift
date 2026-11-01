import Foundation
import Testing
@testable import MacMonitor

struct ExplainServiceTests {
    private func make(_ provider: FakeExplainProvider, key: String? = "SECRET-KEY-123", clock: TestClock = TestClock(), maxConcurrent: Int = 2) -> (ExplainService, VerdictAuditLog) {
        let audit = VerdictAuditLog(directory: tempDirectory(), now: { clock.now })
        let store = MemoryKeyStore(key.map { ["fake": $0] } ?? [:])
        return (ExplainService(providers: [provider], keyStore: store, audit: audit, runner: FakeRunner(), now: { clock.now }, maxConcurrent: maxConcurrent), audit)
    }

    private func request(id: String = "g", tag: UsageTag = .terminate) -> ExplainRequest {
        ExplainRequest(groupID: id, groupName: "next-server", tag: tag, executablePath: "/usr/bin/node", context: "ctx")
    }

    @Test func noKeyOrUnknownProviderReturnsNil() async {
        let provider = FakeExplainProvider()
        let (noKey, _) = make(provider, key: nil)
        #expect(await noKey.explanation(for: request(), providerID: "fake") == nil)
        let (svc, _) = make(provider)
        #expect(await svc.explanation(for: request(), providerID: "unknown") == nil)
        #expect(provider.calls == 0)
    }

    @Test func cacheHitAndTagChange() async {
        let provider = FakeExplainProvider(); let clock = TestClock()
        let (svc, _) = make(provider, clock: clock)
        let first = await svc.explanation(for: request(), providerID: "fake")
        #expect(first?.status == .ok && first?.verdict == .normal && first?.inputTag == .terminate && first?.providerName == "Fake")
        _ = await svc.explanation(for: request(), providerID: "fake")
        #expect(provider.calls == 1)
        #expect(await svc.cached(for: request(), providerID: "fake") != nil)
        _ = await svc.explanation(for: request(tag: .attention), providerID: "fake")
        #expect(provider.calls == 2)
        #expect(await svc.cached(for: request(id: "other"), providerID: "fake") == nil)
        clock.advance(ExplainService.cacheSeconds + 1)
        _ = await svc.explanation(for: request(), providerID: "fake")
        #expect(provider.calls == 3)
    }

    @Test func concurrentSameRequestCallsProviderOnce() async {
        let provider = FakeExplainProvider(); provider.delayMs = 100
        let (svc, _) = make(provider)
        async let a = svc.explanation(for: request(), providerID: "fake")
        async let b = svc.explanation(for: request(), providerID: "fake")
        let (ra, rb) = await (a, b)
        #expect(ra != nil && ra == rb)
        #expect(provider.calls == 1)
    }

    @Test func concurrencyIsLimited() async {
        let provider = FakeExplainProvider(); provider.delayMs = 60
        let (svc, _) = make(provider, maxConcurrent: 2)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<6 { group.addTask { _ = await svc.explanation(for: self.request(id: "g\(i)"), providerID: "fake") } }
        }
        #expect(provider.calls == 6)
        #expect(provider.maxActive == 2)
    }

    @Test func failureIsMaskedLoggedAndCachedBriefly() async {
        let provider = FakeExplainProvider(); let clock = TestClock()
        provider.reply = { .failure(EngineFailure(message: "HTTP 500 SECRET-KEY-123", requestBody: "{}", responseBody: "echo SECRET-KEY-123", httpStatus: 500)) }
        let (svc, audit) = make(provider, clock: clock)
        let out = await svc.explanation(for: request(), providerID: "fake")
        guard case .failed(let message) = out?.status else { Issue.record("failed 아님"); return }
        #expect(!message.contains("SECRET-KEY-123") && message.contains("***"))
        _ = await svc.explanation(for: request(), providerID: "fake")
        #expect(provider.calls == 1)
        clock.advance(ExplainService.failureCacheSeconds + 1)
        _ = await svc.explanation(for: request(), providerID: "fake")
        #expect(provider.calls == 2)
        let entry = await audit.recent(limit: 1)[0]
        #expect(entry.mode == .explain && entry.isFailure && entry.httpStatus == 500 && entry.result == "설명 실패")
        #expect(entry.responseBody?.contains("SECRET-KEY-123") == false)
    }

    @Test func successIsLogged() async {
        let provider = FakeExplainProvider()
        let (svc, audit) = make(provider)
        _ = await svc.explanation(for: request(), providerID: "fake")
        let entry = await audit.recent(limit: 1)[0]
        #expect(entry.mode == .explain && entry.engineID == "fake" && entry.model == "fake-1")
        #expect(entry.inputTokens == 500 && entry.outputTokens == 80 && entry.commands == ["ps -p 1"])
        #expect(entry.result == "정상 · 배지 제거")
        provider.reply = { .success(FakeExplainProvider.reply(verdict: .attention)) }
        _ = await svc.explanation(for: request(tag: .attention), providerID: "fake")
        #expect(await audit.recent(limit: 1)[0].result == "관심 필요 · 유지")
    }

    @Test func hourlyLimitSkipsAndLogs() async {
        let provider = FakeExplainProvider(); let clock = TestClock()
        let (svc, audit) = make(provider, clock: clock)
        for i in 0..<(ExplainService.hourlyLimit + 2) { _ = await svc.explanation(for: request(id: "g\(i)"), providerID: "fake") }
        #expect(provider.calls == ExplainService.hourlyLimit)
        #expect(await audit.recent(limit: 1000).filter(\.isSkipped).count == 2)
        clock.advance(3601)
        _ = await svc.explanation(for: request(id: "new"), providerID: "fake")
        #expect(provider.calls == ExplainService.hourlyLimit + 1)
    }
}
