import Foundation

/// OpenAI (Responses API, raw HTTP) 설명 제공자
struct OpenAIExplainer: ExplainProvider {
    let id = "openai"
    let displayName = "OpenAI"
    /// GPT-6 소형 등급 (공식 문서: "focused, high-volume tasks")
    let model = "gpt-6-luna"

    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let requestTimeout: TimeInterval = 60
    static let totalTimeout: TimeInterval = 120

    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession = URLSession(configuration: .ephemeral), endpoint: URL = OpenAIExplainer.defaultEndpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    func explain(context: String, runner: any CommandRunning, apiKey: String) async throws -> ExplainReply {
        var input: [[String: Any]] = [["role": "user", "content": context]]
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
            let body = try Self.requestBody(model: model, input: input)
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
            case .noCalls:
                guard !nudged else { throw fail("submit_explanation 호출 없이 끝남") }
                nudged = true
                input += response.output
                input.append(["role": "user", "content": ExplainTools.nudgeMessage])
            case .calls(let calls):
                input += response.output
                for call in calls {
                    let output = await execute(call, runner: runner, commands: &commands)
                    input.append(["type": "function_call_output", "call_id": call.callID, "output": output])
                }
            }
        }
        throw fail("도구 왕복 한도(\(ExplainTools.maxRoundTrips)회) 초과")
    }

    private func execute(_ call: FunctionCall, runner: any CommandRunning, commands: inout [String]) async -> String {
        switch call.name {
        case ExplainTools.runCommandName:
            guard let parsed = ExplainTools.parseRunCommand(call.arguments) else { return "오류: " + ExplainTools.invalidRunCommandMessage }
            commands.append(ExplainTools.commandLine(parsed.command, parsed.args))
            let result = await runner.run(command: parsed.command, args: parsed.args)
            return result.isError ? "오류: " + result.output : result.output
        case ExplainTools.submitName:
            return "오류: " + ExplainTools.invalidSubmitMessage
        default:
            return "오류: 알 수 없는 도구: \(call.name)"
        }
    }

    func validate(apiKey: String) async -> Bool {
        let object: [String: Any] = ["model": model, "input": "ping", "max_output_tokens": 16, "store": false]
        guard let body = try? ExplainTools.jsonData(object),
              let (_, status) = try? await send(body: body, apiKey: apiKey, timeout: 15) else { return false }
        return status == 200
    }

    private func send(body: Data, apiKey: String, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - 요청·응답 (순수)

    static var tools: [[String: Any]] { [
        ["type": "function", "name": ExplainTools.runCommandName, "description": ExplainTools.runCommandDescription, "parameters": ExplainTools.runCommandSchema, "strict": true],
        ["type": "function", "name": ExplainTools.submitName, "description": ExplainTools.submitDescription, "parameters": ExplainTools.submitSchema, "strict": true],
    ] }

    /// `store: false` 라 이전 output item(reasoning 포함)을 input 에 그대로 누적한다.
    /// reasoning item 을 되돌려 보내려면 암호화된 내용을 함께 받아야 한다.
    static func requestBody(model: String, input: [[String: Any]]) throws -> Data {
        let object: [String: Any] = [
            "model": model,
            "instructions": ExplainPrompt.systemPrompt,
            "input": input,
            "tools": tools,
            "store": false,
            "include": ["reasoning.encrypted_content"],
        ]
        return try ExplainTools.jsonData(object)
    }

    struct FunctionCall {
        var callID: String
        var name: String
        var arguments: [String: Any]
    }

    struct Response {
        /// output item 원본 (다음 요청 input 에 그대로 누적)
        var output: [[String: Any]]
        var calls: [FunctionCall]
        var incompleteReason: String?
        var refusal: String?
        var inputTokens: Int
        var outputTokens: Int
        var model: String?
    }

    enum Step {
        case submit(ExplainTools.Submission)
        case calls([FunctionCall])
        case noCalls
        case failure(String)
    }

    struct ParseError: Error, LocalizedError {
        var errorDescription: String?
    }

    static func parse(data: Data) throws -> Response {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else {
            throw ParseError(errorDescription: "output 없음")
        }
        let calls = output.compactMap { item -> FunctionCall? in
            guard item["type"] as? String == "function_call", let callID = item["call_id"] as? String, let name = item["name"] as? String else { return nil }
            let args = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            return FunctionCall(callID: callID, name: name, arguments: args)
        }
        let refusal = output.lazy
            .filter { $0["type"] as? String == "message" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .first { $0["type"] as? String == "refusal" }
            .flatMap { $0["refusal"] as? String }
        let usage = root["usage"] as? [String: Any]
        let incomplete = root["status"] as? String == "incomplete"
            ? ((root["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "unknown") : nil
        return Response(
            output: output, calls: calls, incompleteReason: incomplete, refusal: refusal,
            inputTokens: usage?["input_tokens"] as? Int ?? 0, outputTokens: usage?["output_tokens"] as? Int ?? 0,
            model: root["model"] as? String
        )
    }

    static func interpret(_ r: Response) -> Step {
        if let refusal = r.refusal { return .failure("모델이 응답을 거부함: \(refusal)") }
        if let reason = r.incompleteReason { return .failure("응답이 끝까지 생성되지 않음 (\(reason))") }
        if let submit = r.calls.first(where: { $0.name == ExplainTools.submitName }),
           let parsed = ExplainTools.parseSubmission(submit.arguments) {
            return .submit(parsed)
        }
        return r.calls.isEmpty ? .noCalls : .calls(r.calls)
    }
}
