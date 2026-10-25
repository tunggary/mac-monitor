import Foundation

/// 규칙 결과와 AI 판정을 합쳐 행에 붙일 최종 태그를 정한다.
enum FinalTag {
    /// 확신도가 이 값 미만이면 태그 없이 "판단 애매"
    static let confidenceThreshold = 0.7
    /// 데이터 손실 확률이 이 값을 넘으면 종료 추천을 관심 필요로 낮춘다
    static let dataLossThreshold = 0.5

    /// `detail` 은 펼친 영역용 한 줄 (예 "종료 추천 82%")
    static func resolve(rule: RuleOutcome, ai: AIVerdict?, aiEnabled: Bool) -> (tag: UsageTag?, detail: String?) {
        switch rule {
        case .none:
            return (nil, nil)
        case .tag(.attention, _):
            return (.attention, nil)
        case .tag(.terminate, _):
            guard aiEnabled, let loss = ai?.dataLossProbability else { return (.terminate, nil) }
            if loss > dataLossThreshold {
                return (.attention, "데이터 손실 가능성 \(percent(loss))% · 관심 필요로 낮춤")
            }
            return (.terminate, "데이터 손실 가능성 \(percent(loss))%")
        case .ambiguous:
            guard aiEnabled, let ai else { return (nil, nil) }
            switch ai.status {
            case .failed:
                return (nil, "판단 실패")
            case .ambiguous:
                return (nil, "판단 애매" + (ai.choice.map { " · \($0.rawValue) \(percent(ai.topProbability ?? 0))%" } ?? ""))
            case .ok:
                guard let choice = ai.choice else { return (nil, nil) }
                return (choice.tag, "\(choice.rawValue) \(percent(ai.confidence ?? 0))%")
            }
        }
    }

    private static func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
}
