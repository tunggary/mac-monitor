import Foundation

/// 설명 요청의 시스템 프롬프트와 그룹 컨텍스트 (순수)
enum ExplainPrompt {
    static let systemPrompt = """
    너는 개발자 맥에서 메모리를 쓰는 프로세스 그룹에 붙은 배지(종료 추천 / 관심 필요)가 맞는지 검증하는 조사관이다.

    run_command 도구로 읽기 전용 조사를 한 뒤 submit_explanation 으로 답한다.
    - 먼저 대표 pid 에 `ps -o pid,ppid,etime,rss,command -p <pid들>` 을 실행한다. 필요하면 `lsof -p <pid>` 로 열린 파일·포트를 본다.
    - Docker 관련 그룹이면 `docker ps --format ...`, `docker stats --no-stream` 으로 어느 컨테이너가 얼마나 오래 떠 있고 메모리를 얼마나 쓰는지 확인한다.
    - 허용되는 명령은 ps, lsof, pgrep, launchctl(list), docker(ps/top/stats/container ls/compose ls)뿐이다. 거부되면 다른 방법을 쓰되 같은 시도를 반복하지 않는다.
    - 조사는 몇 번 안에 끝낸다. 마지막에는 반드시 submit_explanation 을 호출한다.

    verdict 기준:
    - 종료 추천: 사용자가 쓰지 않고 종료해도 잃을 것이 없다. 띄운 세션이나 터미널이 이미 끝났거나, 보이는 창도 활동도 없이 몇 시간 지났다. 데이터베이스나 진행 중인 작업이 아니다.
    - 관심 필요: 함부로 종료하면 안 된다. 데이터(DB, 저장 안 한 작업, 긴 작업)를 갖고 있거나 메모리가 계속 늘거나 용도가 불분명하다. 종료 전에 사용자가 직접 확인해야 한다.
    - 정상: 지금 쓰이고 있다. 최근 앞에 띄운 창이 있거나 실제 네트워크 연결·지속적인 CPU 작업이 있거나 띄운 터미널이 살아 있다.

    submit_explanation 필드 (모두 한국어, 좁은 팝오버에 들어가므로 짧게):
    - identity: 무슨 프로그램이 무엇을 실행 중인지 한 줄, 40자 이내 (예 "ego lite의 Chromium 렌더러 하위 프로세스 묶음").
    - reason: 그 판정인 이유, 80자 이내 1~2문장. 수치는 꼭 필요한 것만.
    - details: 근거 항목 최대 3개, 각 30자 이내 (예 "postgres:16 · 9일째 · 1.2GB"). 없으면 빈 배열.
    """

    static func context(signals: UsageSignals, group: AppGroup?, rule: RuleOutcome, verdict: AIVerdict?, tag: UsageTag) -> String {
        var lines = [Redactor.stateText(signals)]
        lines.append("현재 배지: \(tag.rawValue)")
        if let reason = rule.reason { lines.append("규칙 근거: \(reason)") }
        if let verdict, let line = jevLine(verdict) { lines.append(line) }
        if let group {
            let subs = group.subgroups.filter { !$0.isOthers }.prefix(6)
            if !subs.isEmpty {
                lines.append("하위 묶음:")
                lines += subs.map { "- \($0.name) · 프로세스 \($0.processCount)개 · \(memory($0.footprint))" }
            }
            var pids = group.subgroups.filter { !$0.isOthers }.flatMap(\.pids)
            if pids.isEmpty { pids = group.pids }
            if !pids.isEmpty {
                lines.append("대표 pid: " + pids.prefix(5).map(String.init).joined(separator: ", "))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func jevLine(_ v: AIVerdict) -> String? {
        if case .failed = v.status { return nil }
        var parts: [String] = []
        if let choice = v.choice {
            parts.append(choice.rawValue + (v.confidence.map { " \(percent($0))" } ?? ""))
        }
        if let loss = v.dataLossProbability { parts.append("데이터 손실 \(percent(loss))") }
        return parts.isEmpty ? nil : "JEV 판정: " + parts.joined(separator: ", ")
    }

    private static func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    private static func memory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1fGB", gb) : "\(bytes / 1_048_576)MB"
    }
}
