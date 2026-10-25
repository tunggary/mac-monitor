import Testing
@testable import MacMonitor

struct FinalTagTests {
    private func ai(_ status: AIVerdict.Status = .ok, _ choice: VerdictChoice? = .terminate, conf: Double? = 0.82, top: Double? = 0.9, loss: Double? = nil) -> AIVerdict {
        AIVerdict(status: status, choice: choice, confidence: conf, topProbability: top, dataLossProbability: loss)
    }

    @Test func noneStaysNone() {
        #expect(FinalTag.resolve(rule: .none, ai: ai(), aiEnabled: true).tag == nil)
    }

    @Test func attentionPassesThrough() {
        let r = FinalTag.resolve(rule: .tag(.attention, reason: "r"), ai: ai(loss: 0.9), aiEnabled: true)
        #expect(r.tag == .attention && r.detail == nil)
    }

    @Test func terminateDowngradesAboveHalf() {
        let r = FinalTag.resolve(rule: .tag(.terminate, reason: "r"), ai: ai(.ok, nil, loss: 0.51), aiEnabled: true)
        #expect(r.tag == .attention)
        #expect(r.detail?.contains("51%") == true)
    }

    @Test func terminateKeptAtOrBelowHalf() {
        #expect(FinalTag.resolve(rule: .tag(.terminate, reason: "r"), ai: ai(.ok, nil, loss: 0.5), aiEnabled: true).tag == .terminate)
        #expect(FinalTag.resolve(rule: .tag(.terminate, reason: "r"), ai: ai(.ok, nil, loss: 0.1), aiEnabled: true).tag == .terminate)
    }

    @Test func terminateWithoutAIOrDisabledIsKept() {
        #expect(FinalTag.resolve(rule: .tag(.terminate, reason: "r"), ai: nil, aiEnabled: true) == (.terminate, nil))
        #expect(FinalTag.resolve(rule: .tag(.terminate, reason: "r"), ai: ai(loss: 0.99), aiEnabled: false) == (.terminate, nil))
        let failed = ai(.failed("x"), nil, conf: nil, top: nil, loss: nil)
        #expect(FinalTag.resolve(rule: .tag(.terminate, reason: "r"), ai: failed, aiEnabled: true).tag == .terminate)
    }

    @Test func ambiguousOkUsesAITag() {
        let r = FinalTag.resolve(rule: .ambiguous(reason: "r"), ai: ai(), aiEnabled: true)
        #expect(r.tag == .terminate && r.detail == "종료 추천 82%")
        let attn = FinalTag.resolve(rule: .ambiguous(reason: "r"), ai: ai(.ok, .attention, conf: 0.7), aiEnabled: true)
        #expect(attn.tag == .attention)
    }

    @Test func ambiguousNormalHasNoTag() {
        let r = FinalTag.resolve(rule: .ambiguous(reason: "r"), ai: ai(.ok, .normal, conf: 0.95), aiEnabled: true)
        #expect(r.tag == nil && r.detail == "정상 95%")
    }

    @Test func ambiguousLowConfidence() {
        let r = FinalTag.resolve(rule: .ambiguous(reason: "r"), ai: ai(.ambiguous, .terminate, conf: 0.4, top: 0.55), aiEnabled: true)
        #expect(r.tag == nil && r.detail == "판단 애매 · 종료 추천 55%")
    }

    @Test func ambiguousFailedOrDisabled() {
        let failed = ai(.failed("x"), nil, conf: nil, top: nil)
        #expect(FinalTag.resolve(rule: .ambiguous(reason: "r"), ai: failed, aiEnabled: true) == (nil, "판단 실패"))
        #expect(FinalTag.resolve(rule: .ambiguous(reason: "r"), ai: ai(), aiEnabled: false) == (nil, nil))
        #expect(FinalTag.resolve(rule: .ambiguous(reason: "r"), ai: nil, aiEnabled: true) == (nil, nil))
    }
}
