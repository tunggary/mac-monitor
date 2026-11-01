import Foundation
import Testing
@testable import MacMonitor

struct RowTagsTests {
    private func verdict(_ choice: VerdictChoice, conf: Double = 0.82) -> AIVerdict {
        AIVerdict(status: .ok, choice: choice, confidence: conf, topProbability: conf, dataLossProbability: nil)
    }

    @Test func ruleTagKeepsReasonWithoutAI() {
        let r = RowTags.compute(outcomes: ["a": .tag(.terminate, reason: "codex 세션 종료됨")], verdicts: [:], aiEnabled: false, pending: false)
        #expect(r["a"] == RowTag(tag: .terminate, reason: "codex 세션 종료됨", detail: nil))
    }

    @Test func noneRowsAreOmitted() {
        #expect(RowTags.compute(outcomes: ["a": .none], verdicts: [:], aiEnabled: true, pending: false).isEmpty)
    }

    @Test func ambiguousShowsPendingOnlyWhileWaiting() {
        let rule: [String: RuleOutcome] = ["a": .ambiguous(reason: "47분째 한가함")]
        #expect(RowTags.compute(outcomes: rule, verdicts: [:], aiEnabled: true, pending: true)["a"]?.detail == "확인 중")
        #expect(RowTags.compute(outcomes: rule, verdicts: [:], aiEnabled: true, pending: false)["a"]?.detail == nil)
        #expect(RowTags.compute(outcomes: rule, verdicts: [:], aiEnabled: false, pending: true)["a"]?.detail == nil)
    }

    @Test func ambiguousTakesAITag() {
        let r = RowTags.compute(outcomes: ["a": .ambiguous(reason: "r")], verdicts: ["a": verdict(.terminate)], aiEnabled: true, pending: false)
        #expect(r["a"]?.tag == .terminate)
        #expect(r["a"]?.evidenceLine == "r · 종료 추천 82%")
    }

    @Test func evidenceLineJoinsOrNil() {
        #expect(RowTag(tag: nil, reason: "a", detail: "b").evidenceLine == "a · b")
        #expect(RowTag(tag: nil, reason: "a", detail: nil).evidenceLine == "a")
        #expect(RowTag(tag: nil, reason: nil, detail: nil).evidenceLine == nil)
    }

    @Test func verdictTargetsOnlyAmbiguousAndTerminate() {
        let signals = ["a": makeSignals(id: "a"), "b": makeSignals(id: "b"), "c": makeSignals(id: "c"), "d": makeSignals(id: "d")]
        let outcomes: [String: RuleOutcome] = [
            "a": .ambiguous(reason: ""), "b": .tag(.terminate, reason: ""), "c": .tag(.attention, reason: ""), "d": .none,
        ]
        let ids = Set(RowTags.verdictTargets(signals: signals, outcomes: outcomes).map { $0.0.groupID })
        #expect(ids == ["a", "b"])
    }
}

struct RowTagsExplainTests {
    private func explanation(_ verdict: VerdictChoice?, input: UsageTag = .terminate, failed: Bool = false) -> AIExplanation {
        AIExplanation(
            status: failed ? .failed("실패") : .ok, verdict: verdict, identity: "정체", reason: "이유", details: ["d"],
            providerName: "Claude", inputTag: input
        )
    }

    private let outcomes: [String: RuleOutcome] = ["a": .tag(.terminate, reason: "r")]

    @Test func normalExplanationRemovesBadgeButKeepsRow() {
        let r = RowTags.compute(outcomes: outcomes, verdicts: [:], aiEnabled: true, pending: false, explanations: ["a": explanation(.normal)])
        #expect(r["a"]?.tag == nil)
        #expect(r["a"]?.explanation == explanation(.normal))
    }

    @Test func attentionExplanationKeepsBadge() {
        let r = RowTags.compute(outcomes: outcomes, verdicts: [:], aiEnabled: true, pending: false, explanations: ["a": explanation(.attention)])
        #expect(r["a"]?.tag == .terminate)
        #expect(r["a"]?.explanation?.verdict == .attention)
    }

    @Test func failedExplanationKeepsBadge() {
        let r = RowTags.compute(outcomes: outcomes, verdicts: [:], aiEnabled: true, pending: false, explanations: ["a": explanation(nil, failed: true)])
        #expect(r["a"]?.tag == .terminate)
        #expect(r["a"]?.explanation != nil)
    }

    @Test func staleExplanationIsIgnored() {
        let r = RowTags.compute(outcomes: outcomes, verdicts: [:], aiEnabled: true, pending: false, explanations: ["a": explanation(.normal, input: .attention)])
        #expect(r["a"]?.tag == .terminate)
        #expect(r["a"]?.explanation == nil)
    }

    @Test func pendingOnlyForTaggedRowsWithoutExplanation() {
        let two: [String: RuleOutcome] = ["a": .tag(.terminate, reason: "r"), "b": .tag(.attention, reason: "r"), "c": .ambiguous(reason: "r")]
        let r = RowTags.compute(
            outcomes: two, verdicts: [:], aiEnabled: true, pending: false,
            explanations: ["b": explanation(.attention, input: .attention)], explainPending: ["a", "b", "c"]
        )
        #expect(r["a"]?.explainPending == true)
        #expect(r["b"]?.explainPending == false)
        #expect(r["c"]?.explainPending == false)
    }

    @Test func explainTargetsUseOriginalTagNotBadgeRemoved() {
        let two: [String: RuleOutcome] = ["a": .tag(.terminate, reason: "r"), "b": .tag(.attention, reason: "r"), "c": .none]
        let base = RowTags.compute(outcomes: two, verdicts: [:], aiEnabled: true, pending: false)
        let targets = RowTags.explainTargets(baseTags: base)
        #expect(targets.map(\.id) == ["a", "b"])
        #expect(targets.map(\.tag) == [.terminate, .attention])
        // 설명을 합친 값에서는 a 의 배지가 사라지므로 대상 선정에 쓰면 안 된다
        let withExplanation = RowTags.compute(outcomes: two, verdicts: [:], aiEnabled: true, pending: false, explanations: ["a": explanation(.normal)])
        #expect(RowTags.explainTargets(baseTags: withExplanation).map(\.id) == ["b"])
    }
}

struct AuditFormatTests {
    @Test func costFormat() {
        #expect(AuditFormat.cost(0) == "$0.00")
        #expect(AuditFormat.cost(0.004) == "$0.01 미만")
        #expect(AuditFormat.cost(0.01) == "$0.01")
        #expect(AuditFormat.cost(1.234) == "$1.23")
    }

    @Test func summaryLine() {
        let s = AuditMonthSummary(calls: 12, inputTokens: 9_800, estimatedCostUSD: 0.41, failures: 1)
        #expect(AuditFormat.summary(s) == "이번 달 12회 · 입력 9,800 토큰 · 약 $0.41 · 실패 1회")
    }

    @Test func prettyJSONAndFallback() {
        #expect(AuditFormat.pretty(#"{"a":1}"#).contains("\n"))
        #expect(AuditFormat.pretty("not json") == "not json")
        #expect(AuditFormat.pretty(nil) == "(없음)")
    }
}
