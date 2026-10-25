import Foundation

/// 행에 보일 최종 값 (배지 + 펼친 영역의 근거 한 줄)
struct RowTag: Equatable {
    var tag: UsageTag?
    var reason: String?
    var detail: String?

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
    static func compute(
        outcomes: [String: RuleOutcome], verdicts: [String: AIVerdict], aiEnabled: Bool, pending: Bool
    ) -> [String: RowTag] {
        outcomes.reduce(into: [:]) { result, item in
            let (id, rule) = item
            var final = FinalTag.resolve(rule: rule, ai: verdicts[id], aiEnabled: aiEnabled)
            if case .ambiguous = rule, aiEnabled, pending, verdicts[id] == nil { final.detail = pendingText }
            let row = RowTag(tag: final.tag, reason: rule.reason, detail: final.detail)
            if row != RowTag() { result[id] = row }
        }
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
