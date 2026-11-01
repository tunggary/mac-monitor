import Foundation

/// Claude (Anthropic Messages API, raw HTTP) 설명 제공자
struct ClaudeExplainer: ExplainProvider {
    let id = "claude"
    let displayName = "Claude"
    let model = "claude-haiku-5-5"

    static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let maxTokens = 16000
    static let requestTimeout: TimeInterval = 60
    static let totalTimeout: TimeInterval = 120

    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession = URLSession(configuration: .ephemeral), endpoint: URL = ClaudeExplainer.defaultEndpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    func explain(context: String, runner: any CommandRunning, apiKey: String) async throws -> ExplainReply {
        var messages: [[String: Any]] = [["role": "user", "content": context]]
        var commands: [String] = []
        var inputTokens = 0, outputTokens = 0
        var lastRequest = "", lastResponse: String?, lastStatus: Int?
        var nudged = false
        let deadline = Date().addingTimeInterval(Self.totalTimeout)

        func fail(_ message: String) -> EngineFailure {
            EngineFailure(message: message, requestBody: lastRequest, responseBody: lastResponse, httpStatus: lastStatus)
        }

        for _ in 0..<ExplainTools.maxRoundTrips {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw fail("전체 시간 초과") }
            let body = try Self.requestBody(model: model, messages: messages)
            lastRequest = String(decoding: body, as: UTF8.self)
            let data: Data, status: Int
            do {
                (data, status) = try await send(body: body, apiKey: apiKey, timeout: min(Self.requestTimeout, remaining))
            } catch {
                throw fail((error as? URLError)?.code == .timedOut ? "타임아웃" : error.localizedDescription)
            }
            lastResponse = String(decoding: data, as: UTF8.self)
            lastStatus = status
            guard status == 200 else { throw fail("HTTP \(status)") }
            let response: Response
            do { response = try Self.parse(data: data) } catch { throw fail("응답 해석 실패: \(error.localizedDescription)") }
            inputTokens += response.inputTokens
            outputTokens += response.outputTokens

            switch Self.interpret(response) {
            case .submit(let s):
                return ExplainReply(
                    verdict: s.verdict, identity: s.identity, reason: s.reason, details: s.details,
                    inputTokens: inputTokens, outputTokens: outputTokens, model: response.model ?? model,
                    requestBody: lastRequest, responseBody: lastResponse ?? "", httpStatus: status, commands: commands
                )
            case .failure(let message):
                throw fail(message)
            case .endTurn:
                guard !nudged else { throw fail("submit_explanation 호출 없이 끝남") }
                nudged = true
                messages.append(["role": "assistant", "content": response.content])
                messages.append(["role": "user", "content": ExplainTools.nudgeMessage])
            case .tools(let uses):
                var results: [[String: Any]] = []
                for use in uses {
                    let (output, isError) = await execute(use, runner: runner, commands: &commands)
                    results.append(["type": "tool_result", "tool_use_id": use.id, "content": output, "is_error": isError])
                }
                messages.append(["role": "assistant", "content": response.content])
                messages.append(["role": "user", "content": results])
            }
        }
        throw fail("도구 왕복 한도(\(ExplainTools.maxRoundTrips)회) 초과")
    }

    private func execute(_ use: ToolUse, runner: any CommandRunning, commands: inout [String]) async -> (String, Bool) {
        switch use.name {
        case ExplainTools.runCommandName:
            guard let call = ExplainTools.parseRunCommand(use.input) else { return (ExplainTools.invalidRunCommandMessage, true) }
            commands.append(ExplainTools.commandLine(call.command, call.args))
            let result = await runner.run(command: call.command, args: call.args)
            return (result.output, result.isError)
        case ExplainTools.submitName:
            return (ExplainTools.invalidSubmitMessage, true)
        default:
            return ("알 수 없는 도구: \(use.name)", true)
        }
    }

    func validate(apiKey: String) async -> Bool {
        let object: [String: Any] = ["model": model, "max_tokens": 16, "messages": [["role": "user", "content": "ping"]]]
        guard let body = try? ExplainTools.jsonData(object),
              let (_, status) = try? await send(body: body, apiKey: apiKey, timeout: 15) else { return false }
        return status == 200
    }

    private func send(body: Data, apiKey: String, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - 요청·응답 (순수)

    static var tools: [[String: Any]] { [
        ["name": ExplainTools.runCommandName, "description": ExplainTools.runCommandDescription, "input_schema": ExplainTools.runCommandSchema, "strict": true],
        ["name": ExplainTools.submitName, "description": ExplainTools.submitDescription, "input_schema": ExplainTools.submitSchema, "strict": true],
    ] }

    /// thinking·tool_choice 는 넣지 않는다 (이 모델은 적응형 기본, 강제 지정은 400).
    static func requestBody(model: String, messages: [[String: Any]]) throws -> Data {
        let object: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": ExplainPrompt.systemPrompt,
            "output_config": ["effort": "low"],
            "tools": tools,
            "messages": messages,
        ]
        return try ExplainTools.jsonData(object)
    }

    struct ToolUse {
        var id: String
        var name: String
        var input: [String: Any]
    }

    struct Response {
        var stopReason: String
        /// 응답 content 배열 원본 (thinking 블록 포함, 수정 없이 assistant 메시지로 되돌려 보낸다)
        var content: [[String: Any]]
        var toolUses: [ToolUse]
        var inputTokens: Int
        var outputTokens: Int
        var model: String?
    }

    enum Step {
        case submit(ExplainTools.Submission)
        case tools([ToolUse])
        case endTurn
        case failure(String)
    }

    struct ParseError: Error, LocalizedError {
        var errorDescription: String?
    }

    static func parse(data: Data) throws -> Response {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stop = root["stop_reason"] as? String,
              let content = root["content"] as? [[String: Any]] else {
            throw ParseError(errorDescription: "stop_reason 또는 content 없음")
        }
        let uses = content.compactMap { block -> ToolUse? in
            guard block["type"] as? String == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
            return ToolUse(id: id, name: name, input: block["input"] as? [String: Any] ?? [:])
        }
        let usage = root["usage"] as? [String: Any]
        return Response(
            stopReason: stop, content: content, toolUses: uses,
            inputTokens: usage?["input_tokens"] as? Int ?? 0, outputTokens: usage?["output_tokens"] as? Int ?? 0,
            model: root["model"] as? String
        )
    }

    static func interpret(_ r: Response) -> Step {
        switch r.stopReason {
        case "refusal": return .failure("모델이 응답을 거부함 (refusal)")
        case "max_tokens": return .failure("출력 토큰 한도(max_tokens)에 걸려 잘림")
        default: break
        }
        if let submit = r.toolUses.first(where: { $0.name == ExplainTools.submitName }),
           let parsed = ExplainTools.parseSubmission(submit.input) {
            return .submit(parsed)
        }
        switch r.stopReason {
        case "tool_use" where !r.toolUses.isEmpty: return .tools(r.toolUses)
        case "end_turn": return .endTurn
        default: return .failure("예상하지 못한 stop_reason: \(r.stopReason)")
        }
    }
}
