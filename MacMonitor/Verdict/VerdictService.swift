import Foundation

/// 엔진 응답을 규칙 계층이 쓰기 좋게 정리한 값
struct AIVerdict: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case ok
        /// 확신도 0.7 미만
        case ambiguous
        case failed(String)
    }

    var status: Status
    /// `.dataLossOnly` 에서는 nil
    var choice: VerdictChoice?
    var confidence: Double?
    /// 고른 선택지의 확률 ("판단 애매" 표기용)
    var topProbability: Double?
    var dataLossProbability: Double?

    var tag: UsageTag? { choice?.tag }
}

/// AI 판정 호출 계층: 켜짐·키 확인, 모드 선택, 병렬 호출, 캐시, 시간당 상한, 기록.
actor VerdictService {
    static let cacheSeconds: TimeInterval = 300
    static let hourlyLimit = 300

    private struct CacheEntry {
        var verdict: AIVerdict
        var mode: VerdictMode
        var time: Date
        var wasIdle: Bool
        var footprint: UInt64
    }

    private let engines: [String: any VerdictEngine]
    private let keyStore: any APIKeyStore
    private let audit: VerdictAuditLog
    private let now: @Sendable () -> Date
    private var cache: [String: CacheEntry] = [:]
    private var callTimes: [Date] = []

    init(
        engines: [any VerdictEngine] = VerdictEngines.all,
        keyStore: any APIKeyStore,
        audit: VerdictAuditLog,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
        self.keyStore = keyStore
        self.audit = audit
        self.now = now
    }

    func verdicts(for items: [(UsageSignals, RuleOutcome)], enabled: Bool, engineID: String) async -> [String: AIVerdict] {
        guard enabled, let engine = engines[engineID],
              let apiKey = keyStore.key(for: engineID), !apiKey.isEmpty else { return [:] }

        var result: [String: AIVerdict] = [:]
        var pending: [(signals: UsageSignals, rule: RuleOutcome, mode: VerdictMode)] = []
        let current = now()
        callTimes.removeAll { current.timeIntervalSince($0) >= 3600 }

        for (signals, rule) in items {
            let mode: VerdictMode
            switch rule {
            case .ambiguous: mode = .full
            case .tag(.terminate, _): mode = .dataLossOnly
            default: continue
            }
            if let hit = cached(signals, mode: mode, at: current) {
                result[signals.groupID] = hit
            } else if callTimes.count >= Self.hourlyLimit {
                await audit.append(entry(engine, signals, mode, time: current, result: VerdictAuditEntry.skippedRateLimit))
            } else {
                callTimes.append(current)
                pending.append((signals, rule, mode))
            }
        }

        let outcomes = await withTaskGroup(of: (Int, Result<EngineReply, Error>, Int).self) { group in
            for (index, item) in pending.enumerated() {
                let state = Redactor.stateText(item.signals)
                group.addTask {
                    let start = ContinuousClock.now
                    let reply: Result<EngineReply, Error>
                    do { reply = .success(try await engine.judge(state: state, mode: item.mode, apiKey: apiKey)) } catch { reply = .failure(error) }
                    let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
                    return (index, reply, ms)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        for (index, reply, latency) in outcomes.sorted(by: { $0.0 < $1.0 }) {
            let item = pending[index]
            var log = entry(engine, item.signals, item.mode, time: current, result: "")
            log.latencyMs = latency
            let verdict: AIVerdict
            switch reply {
            case .success(let r):
                verdict = Self.verdict(from: r)
                cache[item.signals.groupID] = CacheEntry(
                    verdict: verdict, mode: item.mode, time: current,
                    wasIdle: item.signals.idleSeconds > 0, footprint: item.signals.footprint
                )
                log.model = r.model
                log.requestBody = r.requestBody
                log.responseBody = r.responseBody
                log.httpStatus = r.httpStatus
                log.inputTokens = r.inputTokens
                log.outputTokens = r.outputTokens
                log.confidence = r.confidence
                let final = FinalTag.resolve(rule: item.rule, ai: verdict, aiEnabled: true)
                log.result = [final.tag?.rawValue ?? "태그 없음", final.detail].compactMap { $0 }.joined(separator: " · ")
            case .failure(let error):
                let failure = error as? EngineFailure
                let message = (failure?.message ?? error.localizedDescription).replacingOccurrences(of: apiKey, with: Redactor.mask)
                verdict = AIVerdict(status: .failed(message), choice: nil, confidence: nil, topProbability: nil, dataLossProbability: nil)
                log.requestBody = failure?.requestBody
                log.responseBody = failure?.responseBody?.replacingOccurrences(of: apiKey, with: Redactor.mask)
                log.httpStatus = failure?.httpStatus
                log.error = message
                log.result = "판단 실패"
            }
            result[item.signals.groupID] = verdict
            await audit.append(log)
        }
        return result
    }

    private func cached(_ s: UsageSignals, mode: VerdictMode, at time: Date) -> AIVerdict? {
        guard let hit = cache[s.groupID], hit.mode == mode,
              time.timeIntervalSince(hit.time) < Self.cacheSeconds,
              hit.wasIdle == (s.idleSeconds > 0),
              s.footprint < hit.footprint * 2 else { return nil }
        return hit.verdict
    }

    private func entry(_ engine: any VerdictEngine, _ s: UsageSignals, _ mode: VerdictMode, time: Date, result: String) -> VerdictAuditEntry {
        VerdictAuditEntry(
            time: time, engineID: engine.id, groupID: s.groupID, groupName: s.displayName, mode: mode,
            latencyMs: 0, inputTokens: 0, outputTokens: 0, result: result
        )
    }

    static func verdict(from reply: EngineReply) -> AIVerdict {
        let ambiguous = (reply.confidence ?? 1) < FinalTag.confidenceThreshold
        return AIVerdict(
            status: ambiguous ? .ambiguous : .ok,
            choice: reply.verdict,
            confidence: reply.confidence,
            topProbability: reply.verdict.flatMap { reply.probabilities[$0.rawValue] },
            dataLossProbability: reply.dataLossProbability
        )
    }
}
