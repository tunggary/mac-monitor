import Foundation

/// 엔진에 보내기 전 신호를 가린다 (순수). 환경변수는 UsageSignals 에 없으므로 애초에 보내지 않는다.
enum Redactor {
    static let mask = "***"
    private static let sensitiveNames = ["token", "key", "secret", "password", "auth"]

    /// 엔진에 보내는 state — 사실 문장 목록. 값이 없는 사실은 줄을 뺀다.
    static func stateText(_ s: UsageSignals, home: String = NSHomeDirectory()) -> String {
        var lines: [String] = []
        var head = "\(s.displayName) (\(s.kind == .app ? "앱" : "명령줄 도구")), 프로세스 \(s.processCount)개"
        if s.sameNameMaxCount > 1 { head += " (같은 이름 최대 \(s.sameNameMaxCount)개)" }
        lines.append(head + ".")
        let command = summarizeCommand(path: s.executablePath, arguments: s.arguments, home: home)
        if !command.isEmpty { lines.append("대표 실행 명령: \(command)") }
        if let cwd = s.cwd, cwd != "/" { lines.append("작업 폴더: \(redactPaths(cwd, home: home))") }
        if let lost = s.lostAncestor {
            lines.append("이 프로세스를 띄운 \(ancestorLabel(lost)) 세션은 이미 종료됨.")
        } else if s.isOrphan {
            lines.append("이 프로세스를 띄운 부모 프로세스가 없음.")
        }
        if let live = s.liveAncestor { lines.append("이 프로세스를 띄운 \(ancestorLabel(live)) 세션이 살아 있음.") }
        lines.append("실행된 지 \(duration(s.uptimeSeconds)).")
        if s.idleSeconds >= 300 {
            lines.append("\(duration(s.idleSeconds))째 CPU 1% 미만·네트워크 연결 0개.")
        } else {
            lines.append("지금 CPU \(number(s.cpuPercent))%, 네트워크 연결 \(s.establishedConnections)개.")
        }
        if !s.ports.isEmpty { lines.append("열린 포트: " + s.ports.map(String.init).joined(separator: ", ") + ".") }
        lines.append("메모리 " + String(format: "%.1f", Double(s.footprint) / 1_073_741_824) + "GB.")
        if let growth = s.footprintGrowthPercent, growth >= 10 {
            lines.append("최근 30분간 메모리 +\(Int(growth.rounded()))%" + (s.footprintMonotonic ? " (단조 증가)" : "") + ".")
        }
        if let last = s.lastActiveSeconds {
            lines.append(s.activeSinceMonitorStart ? "마지막으로 앞에 띄운 지 \(duration(last))." : "\(duration(last)) 넘게 앞에 띄운 적 없음.")
        }
        if let visible = s.hasVisibleWindow { lines.append(visible ? "보이는 창 있음." : "보이는 창 없음.") }
        return lines.map { "- " + $0 }.joined(separator: "\n")
    }

    /// 실행 파일 이름 + 앞 3개 인자. `--` 플래그는 빼고 경로는 파일명만 남긴다. 비밀값은 가린 뒤에 고른다.
    static func summarizeCommand(path: String?, arguments: [String], home: String) -> String {
        let name = path.map { ($0 as NSString).lastPathComponent } ?? arguments.first.map { ($0 as NSString).lastPathComponent }
        guard let name else { return "" }
        let kept = redactArguments(Array(arguments.dropFirst()), home: home)
            .filter { !$0.hasPrefix("--") }
            .map { $0.contains("/") ? ($0 as NSString).lastPathComponent : $0 }
            .prefix(3)
        return ([name] + kept).joined(separator: " ")
    }

    /// claude·codex 는 그대로, 셸·터미널 앱은 "터미널"
    private static func ancestorLabel(_ name: String) -> String {
        UsageTracker.agentNames.contains(name.lowercased()) ? name.lowercased() : "터미널"
    }

    /// 2일 이상 "N일", 1시간 이상 "N시간 M분", 그 외 "N분" (최소 1분)
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 2 * 86400 { return "\(s / 86400)일" }
        if s >= 3600 {
            let minutes = s / 60 % 60
            return "\(s / 3600)시간" + (minutes > 0 ? " \(minutes)분" : "")
        }
        return "\(max(s / 60, 1))분"
    }

    private static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    // MARK: - 경로

    /// 홈 경로를 "~" 로 바꾼다. `/Users/me2` 처럼 홈 이름으로 시작하는 다른 경로는 건드리지 않는다.
    static func redactPaths(_ text: String, home: String) -> String {
        guard home.count > 1 else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: home) {
            result += rest[..<range.lowerBound]
            let next = rest[range.upperBound...].first
            if next == nil || next == "/" || !(next!.isLetter || next!.isNumber || next! == "-" || next! == "_" || next! == ".") {
                result += "~"
            } else {
                result += home
            }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    // MARK: - 인자

    static func redactArguments(_ arguments: [String], home: String) -> [String] {
        var out: [String] = []
        var maskNext = false
        for argument in arguments {
            if maskNext {
                maskNext = false
                if !argument.hasPrefix("-") {
                    out.append(mask)
                    continue
                }
            }
            if let eq = argument.firstIndex(of: "="), isOptionName(argument[..<eq]) {
                let name = String(argument[..<eq])
                let value = String(argument[argument.index(after: eq)...])
                let masked = isSensitive(name) || looksRandom(value) ? mask : redactPaths(value, home: home)
                out.append("\(redactPaths(name, home: home))=\(masked)")
            } else if argument.hasPrefix("-"), isSensitive(argument) {
                out.append(argument)
                maskNext = true
            } else {
                out.append(looksRandom(argument) ? mask : redactPaths(argument, home: home))
            }
        }
        return out
    }

    /// `--token`, `PASSWORD`, `api.key` 처럼 옵션·변수 이름으로 보이는가 (경로·URL 이 아님)
    private static func isOptionName(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    private static func isSensitive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return sensitiveNames.contains { lower.contains($0) }
    }

    /// 20자 이상 영숫자/base64/hex 로 보이는 무작위 문자열인가.
    /// 경로("/" 포함)·점이 든 이름·한글 등은 일반 단어로 보고 보존한다.
    static func looksRandom(_ s: String) -> Bool {
        guard s.count >= 20, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+_=-".contains($0)) }) else { return false }
        let stripped = s.filter { $0 != "-" }
        if stripped.count >= 20, stripped.allSatisfy({ $0.isHexDigit }) { return true }
        let digits = s.filter(\.isNumber).count
        let upper = s.filter(\.isUppercase).count
        let lower = s.filter(\.isLowercase).count
        if digits >= 2, upper >= 1, lower >= 1 { return true }
        return !s.contains(where: { "-_".contains($0) }) && digits >= 3 && lower >= 3 && upper == 0
    }
}
