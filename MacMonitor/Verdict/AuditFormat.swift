import Foundation

/// 설정 창 "AI 판정 기록"의 표기 (순수 함수)
enum AuditFormat {
    /// 소수 둘째 자리. 0.01 미만(0 제외)은 "$0.01 미만".
    static func cost(_ usd: Double) -> String {
        if usd <= 0 { return "$0.00" }
        return usd < 0.01 ? "$0.01 미만" : String(format: "$%.2f", usd)
    }

    static func summary(_ s: AuditMonthSummary) -> String {
        let tokens = s.inputTokens.formatted(.number.locale(Locale(identifier: "en_US")))
        return "이번 달 \(s.calls)회 · 입력 \(tokens) 토큰 · 약 \(cost(s.estimatedCostUSD)) · 실패 \(s.failures)회"
    }

    static func status(_ e: VerdictAuditEntry) -> String {
        if e.isSkipped { return "건너뜀" }
        return e.isFailure ? "실패" : "성공"
    }

    /// JSON 이면 보기 좋게 들여 쓰고, 아니면 원문 그대로.
    static func pretty(_ body: String?) -> String {
        guard let body, !body.isEmpty else { return "(없음)" }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8) else { return body }
        return text
    }
}
