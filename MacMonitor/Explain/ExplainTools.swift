import Foundation

/// 두 제공자가 공유하는 도구 정의와 입력 해석 (순수)
enum ExplainTools {
    static let runCommandName = "run_command"
    static let submitName = "submit_explanation"
    static let allowedCommands = ["ps", "lsof", "pgrep", "launchctl", "docker"]
    /// 도구 왕복 한도
    static let maxRoundTrips = 8
    /// 팝오버 카드에 보이는 근거 칩 수
    static let maxDetails = 3
    static let nudgeMessage = "submit_explanation 도구로 답해 주세요."

    static let runCommandDescription = "읽기 전용 조사 명령 하나를 실행하고 출력을 돌려준다. 셸이 아니라 argv 로 실행되며 허용 목록 밖의 명령·인자는 거부된다."
    static let submitDescription = "조사를 마친 뒤 최종 설명과 판정을 제출한다. 마지막에 반드시 한 번 호출한다."

    static var runCommandSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "command": ["type": "string", "enum": allowedCommands],
            "args": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["command", "args"],
        "additionalProperties": false,
    ] }

    static var submitSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "verdict": ["type": "string", "enum": ["종료 추천", "관심 필요", "정상"]],
            "identity": ["type": "string", "description": "정체 한 줄, 40자 이내"],
            "reason": ["type": "string", "description": "판정 이유, 80자 이내"],
            "details": ["type": "array", "items": ["type": "string"], "description": "근거 최대 \(maxDetails)개, 각 30자 이내"],
        ],
        "required": ["verdict", "identity", "reason", "details"],
        "additionalProperties": false,
    ] }

    struct Submission: Sendable, Equatable {
        var verdict: VerdictChoice
        var identity: String
        var reason: String
        var details: [String]
    }

    static func parseSubmission(_ input: [String: Any]) -> Submission? {
        guard let verdict = (input["verdict"] as? String).flatMap(VerdictChoice.init(rawValue:)),
              let identity = input["identity"] as? String,
              let reason = input["reason"] as? String,
              let details = input["details"] as? [String] else { return nil }
        return Submission(verdict: verdict, identity: identity, reason: reason, details: Array(details.prefix(maxDetails)))
    }

    static func parseRunCommand(_ input: [String: Any]) -> (command: String, args: [String])? {
        guard let command = input["command"] as? String, allowedCommands.contains(command),
              let args = input["args"] as? [String] else { return nil }
        return (command, args)
    }

    static func commandLine(_ command: String, _ args: [String]) -> String {
        ([command] + args).joined(separator: " ")
    }

    static let invalidRunCommandMessage = "입력이 스키마와 맞지 않음: command 는 \(allowedCommands.joined(separator: "/")) 중 하나, args 는 문자열 배열이어야 한다."
    static let invalidSubmitMessage = "입력이 스키마와 맞지 않음: verdict(종료 추천/관심 필요/정상), identity, reason, details(문자열 배열)가 모두 필요하다."

    static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func jsonText(_ object: Any) throws -> String {
        String(decoding: try jsonData(object), as: UTF8.self)
    }
}
