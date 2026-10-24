import Foundation

/// 엔진에 보내기 전 신호를 가린다 (순수). 환경변수는 UsageSignals 에 없으므로 애초에 보내지 않는다.
enum Redactor {
    static let mask = "***"
    private static let sensitiveNames = ["token", "key", "secret", "password", "auth"]

    /// 정렬된 키의 JSON 문자열. 값이 없는 필드는 뺀다.
    static func stateJSON(_ s: UsageSignals, home: String = NSHomeDirectory()) -> String {
        var object: [String: Any] = [
            "name": s.displayName,
            "kind": kindName(s.kind),
            "arguments": redactArguments(s.arguments, home: home),
            "ports": s.ports.map(Int.init),
            "establishedConnections": s.establishedConnections,
            "processCount": s.processCount,
            "sameNameMaxCount": s.sameNameMaxCount,
            "uptimeSeconds": Int(s.uptimeSeconds),
            "idleSeconds": Int(s.idleSeconds),
            "isOrphan": s.isOrphan,
            "footprintMB": Int(s.footprint / 1_048_576),
            "footprintMonotonicGrowth": s.footprintMonotonic,
            "cpuPercent": round(s.cpuPercent * 10) / 10,
        ]
        if let path = s.executablePath { object["executable"] = redactPaths(path, home: home) }
        if let cwd = s.cwd { object["cwd"] = redactPaths(cwd, home: home) }
        if let ancestor = s.lostAncestor { object["lostAncestor"] = ancestor }
        if let growth = s.footprintGrowthPercent { object["footprintGrowthPercent30m"] = round(growth * 10) / 10 }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func kindName(_ kind: GroupKind) -> String {
        switch kind {
        case .app: "app"
        case .cli: "cli"
        case .process: "process"
        }
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
