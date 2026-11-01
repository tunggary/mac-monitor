import Foundation

struct ExplainRequest: Sendable {
    var groupID: String
    var groupName: String
    /// 설명을 요청하는 시점의 배지
    var tag: UsageTag
    var executablePath: String?
    /// 가린 뒤의 그룹 설명 (`ExplainPrompt.context`)
    var context: String
}

/// AI 설명 호출 계층: 캐시, 진행 중 호출 공유, 동시 실행 제한, 시간당 상한, 기록.
actor ExplainService {
    static let cacheSeconds: TimeInterval = 1800
    static let failureCacheSeconds: TimeInterval = 120
    static let hourlyLimit = 60

    private struct CacheEntry {
        var explanation: AIExplanation
        var time: Date
        var ttl: TimeInterval
    }

    private let providers: [String: any ExplainProvider]
    private let keyStore: any APIKeyStore
    private let audit: VerdictAuditLog
    private let runner: any CommandRunning
    private let now: @Sendable () -> Date
    private let maxConcurrent: Int
    private var cache: [String: CacheEntry] = [:]
    private var inflight: [String: Task<AIExplanation?, Never>] = [:]
    private var callTimes: [Date] = []
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        providers: [any ExplainProvider] = ExplainProviders.all,
        keyStore: any APIKeyStore,
        audit: VerdictAuditLog,
        runner: any CommandRunning = SystemCommandRunner(),
        now: @escaping @Sendable () -> Date = { Date() },
        maxConcurrent: Int = 2
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.keyStore = keyStore
        self.audit = audit
        self.runner = runner
        self.now = now
        self.maxConcurrent = maxConcurrent
    }

    private static func cacheKey(_ r: ExplainRequest, _ providerID: String) -> String {
        [r.groupID, r.tag.rawValue, r.executablePath ?? "", providerID].joined(separator: "\u{1f}")
    }

    /// 호출 없이 캐시만 본다 (UI 용)
    func cached(for request: ExplainRequest, providerID: String) -> AIExplanation? {
        lookup(Self.cacheKey(request, providerID), at: now())
    }

    /// 키가 없거나 상한을 넘으면 nil. 같은 키로 진행 중인 호출이 있으면 그 결과를 기다린다.
    func explanation(for request: ExplainRequest, providerID: String) async -> AIExplanation? {
        guard let provider = providers[providerID],
              let apiKey = keyStore.key(for: providerID), !apiKey.isEmpty else { return nil }
        let key = Self.cacheKey(request, providerID)
        let current = now()
        if let hit = lookup(key, at: current) { return hit }
        if let task = inflight[key] { return await task.value }

        callTimes.removeAll { current.timeIntervalSince($0) >= 3600 }
        guard callTimes.count < Self.hourlyLimit else {
            await audit.append(entry(provider, request, time: current, result: VerdictAuditEntry.skippedRateLimit))
            return nil
        }
        callTimes.append(current)

        let task = Task { await self.perform(request, provider: provider, apiKey: apiKey, key: key) }
        inflight[key] = task
        return await task.value
    }

    private func lookup(_ key: String, at time: Date) -> AIExplanation? {
        guard let hit = cache[key], time.timeIntervalSince(hit.time) < hit.ttl else { return nil }
        return hit.explanation
    }

    private func perform(_ request: ExplainRequest, provider: any ExplainProvider, apiKey: String, key: String) async -> AIExplanation? {
        await acquire()
        let start = now()
        let clock = ContinuousClock.now
        let outcome: Result<ExplainReply, Error>
        do { outcome = .success(try await provider.explain(context: request.context, runner: runner, apiKey: apiKey)) } catch { outcome = .failure(error) }
        release()

        var log = entry(provider, request, time: start, result: "")
        log.latencyMs = Int((ContinuousClock.now - clock) / .milliseconds(1))
        let mask: (String) -> String = { $0.replacingOccurrences(of: apiKey, with: Redactor.mask) }
        let explanation: AIExplanation
        let ttl: TimeInterval
        switch outcome {
        case .success(let r):
            explanation = AIExplanation(
                status: .ok, verdict: r.verdict, identity: mask(r.identity), reason: mask(r.reason),
                details: r.details.map(mask), providerName: provider.displayName, inputTag: request.tag
            )
            ttl = Self.cacheSeconds
            log.model = r.model
            log.requestBody = mask(r.requestBody)
            log.responseBody = mask(r.responseBody)
            log.httpStatus = r.httpStatus
            log.inputTokens = r.inputTokens
            log.outputTokens = r.outputTokens
            log.commands = r.commands.map(mask)
            log.result = r.verdict == .normal ? "정상 · 배지 제거" : "\(r.verdict.rawValue) · 유지"
        case .failure(let error):
            let failure = error as? EngineFailure
            let message = mask(failure?.message ?? error.localizedDescription)
            explanation = AIExplanation(
                status: .failed(message), verdict: nil, identity: "", reason: "", details: [],
                providerName: provider.displayName, inputTag: request.tag
            )
            ttl = Self.failureCacheSeconds
            log.requestBody = failure.map { mask($0.requestBody) }
            log.responseBody = failure?.responseBody.map(mask)
            log.httpStatus = failure?.httpStatus
            log.error = message
            log.result = "설명 실패"
        }
        cache[key] = CacheEntry(explanation: explanation, time: now(), ttl: ttl)
        inflight[key] = nil
        await audit.append(log)
        return explanation
    }

    private func acquire() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    private func entry(_ provider: any ExplainProvider, _ r: ExplainRequest, time: Date, result: String) -> VerdictAuditEntry {
        VerdictAuditEntry(
            time: time, engineID: provider.id, groupID: r.groupID, groupName: r.groupName, mode: .explain,
            latencyMs: 0, inputTokens: 0, outputTokens: 0, result: result
        )
    }
}
