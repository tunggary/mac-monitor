import Foundation

/// 행에 보일 최종 값 (배지 + 펼친 영역의 근거 한 줄)
struct RowTag: Equatable {
    var tag: UsageTag?
    var reason: String?
    var detail: String?
    var explanation: AIExplanation?
    var explainPending = false

    /// 펼친 영역 맨 위 한 줄. 둘 다 없으면 nil.
    var evidenceLine: String? {
        let parts = [reason, detail].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 규칙 결과 + AI 판정 → 행 표시값 (순수 함수)
enum RowTags {
    static let pendingText = "확인 중"

    /// `pending` 이면 AI 결과를 기다리는 판단 보류 행에 "확인 중"을 보인다 (태그는 없음).
    /// AI 설명: 설명을 요청했을 때의 배지(`inputTag`)가 지금 배지와 같을 때만 쓴다. 정상으로 봤으면 배지를 뗀다(행은 남는다).
    static func compute(
        outcomes: [String: RuleOutcome], verdicts: [String: AIVerdict], aiEnabled: Bool, pending: Bool,
        explanations: [String: AIExplanation] = [:], explainPending: Set<String> = []
    ) -> [String: RowTag] {
        outcomes.reduce(into: [:]) { result, item in
            let (id, rule) = item
            var final = FinalTag.resolve(rule: rule, ai: verdicts[id], aiEnabled: aiEnabled)
            if case .ambiguous = rule, aiEnabled, pending, verdicts[id] == nil { final.detail = pendingText }
            var row = RowTag(tag: final.tag, reason: rule.reason, detail: final.detail)
            if let original = final.tag {
                if let explanation = explanations[id], explanation.inputTag == original {
                    row.explanation = explanation
                    if explanation.status == .ok, explanation.verdict == .normal { row.tag = nil }
                } else if explainPending.contains(id) {
                    row.explainPending = true
                }
            }
            if row != RowTag() { result[id] = row }
        }
    }

    /// AI 설명을 부를 대상: 배지가 붙은 행. `baseTags` 는 설명 없이 계산한 값이어야 한다(배지 제거 전 원래 태그 기준).
    static func explainTargets(baseTags: [String: RowTag]) -> [(id: String, tag: UsageTag)] {
        baseTags.compactMap { id, row in row.tag.map { (id, $0) } }.sorted { $0.id < $1.id }
    }

    /// AI 판정을 부를 대상: 판단 보류 / 종료 추천 행만
    static func verdictTargets(signals: [String: UsageSignals], outcomes: [String: RuleOutcome]) -> [(UsageSignals, RuleOutcome)] {
        outcomes.compactMap { id, rule in
            switch rule {
            case .ambiguous, .tag(.terminate, _): signals[id].map { ($0, rule) }
            default: nil
            }
        }
    }
}
