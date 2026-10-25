import Foundation

/// 신호 → 규칙 1차 판정. 기준값은 코드 상수 (설정 노출 없음).
enum UsageRules {
    static let idleThreshold: TimeInterval = 30 * 60
    static let growthThresholdPercent = 50.0
    static let sameNameThreshold = 10

    static func evaluate(_ s: UsageSignals) -> RuleOutcome {
        let isIdle = s.idleSeconds >= idleThreshold
        if s.isOrphan, isIdle {
            let idle = duration(s.idleSeconds)
            if let lost = s.lostAncestor {
                return .tag(.terminate, reason: "\(lostText(lost)) · \(idle) CPU 0%")
            }
            return .tag(.terminate, reason: "부모 프로세스 없음 · \(idle) 한가함")
        }
        if s.footprintMonotonic, let growth = s.footprintGrowthPercent, growth >= growthThresholdPercent {
            return .tag(.attention, reason: "30분 동안 메모리 +\(Int(growth.rounded()))%")
        }
        var parts: [String] = []
        if s.sameNameMaxCount >= sameNameThreshold { parts.append("같은 프로세스 \(s.sameNameMaxCount)개") }
        if isIdle { parts.append("\(duration(s.idleSeconds)) 한가함") }
        if (!s.isOrphan && isIdle) || s.sameNameMaxCount >= sameNameThreshold {
            return .ambiguous(reason: parts.joined(separator: " · "))
        }
        return .none
    }

    private static func lostText(_ ancestor: String) -> String {
        let name = ancestor.lowercased()
        return name == "claude" || name == "codex" ? "\(name) 세션 종료됨" : "터미널 종료됨"
    }

    /// 60분 미만 "N분째", 이상 "N시간째"
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)분째" : "\(minutes / 60)시간째"
    }
}
