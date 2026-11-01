import Foundation
import Testing
@testable import MacMonitor

struct ClaudeExplainerTests {
    private func response(stop: String, content: String) -> String {
        "{\"stop_reason\":\"\(stop)\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20},\"content\":\(content)}"
    }

    private let submitBlock = """
    [{"type":"tool_use","id":"t2","name":"submit_explanation","input":{"verdict":"정상","identity":"node 서버","reason":"쓰는 중","details":["a"]}}]
    """
    private let commandBlock = """
    [{"type":"thinking","thinking":"hm","signature":"sig"},{"type":"tool_use","id":"t1","name":"run_command","input":{"command":"ps","args":["-p","1"]}}]
    """

    @Test func requestBodyShape() throws {
        let data = try ClaudeExplainer.requestBody(model: "claude-haiku-5-5", messages: [["role": "user", "content": "hi"]])
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["model"] as? String == "claude-haiku-5-5")
        #expect((obj["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(obj["fallbacks"] == nil)
        #expect(obj["max_tokens"] as? Int == 16000)
        #expect(obj["thinking"] == nil && obj["tool_choice"] == nil)
        let tools = try #require(obj["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["run_command", "submit_explanation"])
        #expect(tools.allSatisfy { $0["strict"] as? Bool == true && $0["input_schema"] != nil })
    }

    @Test func parseSubmit() throws {
        let r = try ClaudeExplainer.parse(data: Data(response(stop: "tool_use", content: submitBlock).utf8))
        guard case .submit(let s) = ClaudeExplainer.interpret(r) else { Issue.record("submit 아님"); return }
        #expect(s.verdict == .normal && s.identity == "node 서버" && s.details == ["a"])
        #expect(r.inputTokens == 100 && r.outputTokens == 20)
    }

    @Test func parseRunCommand() throws {
        let r = try ClaudeExplainer.parse(data: Data(response(stop: "tool_use", content: commandBlock).utf8))
        guard case .tools(let uses) = ClaudeExplainer.interpret(r) else { Issue.record("tools 아님"); return }
        #expect(uses.count == 1 && uses[0].id == "t1")
        let call = ExplainTools.parseRunCommand(uses[0].input)
        #expect(call?.command == "ps" && call?.args == ["-p", "1"])
        #expect(r.content.count == 2)
    }

    @Test func refusalAndMaxTokensFail() throws {
        for stop in ["refusal", "max_tokens"] {
            let r = try ClaudeExplainer.parse(data: Data(response(stop: stop, content: "[]").utf8))
            guard case .failure = ClaudeExplainer.interpret(r) else { Issue.record("\(stop) 실패 아님"); return }
        }
    }

    @Test func endTurnWithoutSubmit() throws {
        let r = try ClaudeExplainer.parse(data: Data(response(stop: "end_turn", content: "[{\"type\":\"text\",\"text\":\"x\"}]").utf8))
        guard case .endTurn = ClaudeExplainer.interpret(r) else { Issue.record("endTurn 아님"); return }
    }

    @Test func twoRoundTripLoop() async throws {
        let endpoint = StubURLProtocol.uniqueEndpoint(path: "/v1/messages")
        let server = ScriptedServer([response(stop: "tool_use", content: commandBlock), response(stop: "tool_use", content: submitBlock)])
        server.serve(host: endpoint.host!)
        let runner = FakeRunner()
        let explainer = ClaudeExplainer(session: StubURLProtocol.makeSession(), endpoint: endpoint)
        let reply = try await explainer.explain(context: "ctx", runner: runner, apiKey: "K")
        #expect(reply.verdict == .normal && reply.commands == ["ps -p 1"] && runner.calls == ["ps -p 1"])
        #expect(reply.inputTokens == 200 && reply.outputTokens == 40)
        let headers = server.headers[0]
        #expect(headers["x-api-key"] == "K" && headers["anthropic-version"] == "2026-10-21" && headers["anthropic-beta"] == nil)
        // 두 번째 요청: assistant(thinking 포함 그대로) + user(tool_result 하나)
        let messages = try #require(server.bodies[1]["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant.first?["type"] as? String == "thinking" && assistant.first?["signature"] as? String == "sig")
        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(results.count == 1 && results[0]["tool_use_id"] as? String == "t1" && results[0]["is_error"] as? Bool == false)
    }

    @Test func httpErrorBecomesFailure() async {
        let endpoint = StubURLProtocol.uniqueEndpoint(path: "/v1/messages")
        StubURLProtocol.register(host: endpoint.host!) { _, _ in (400, Data("bad".utf8)) }
        let explainer = ClaudeExplainer(session: StubURLProtocol.makeSession(), endpoint: endpoint)
        do {
            _ = try await explainer.explain(context: "c", runner: FakeRunner(), apiKey: "K")
            Issue.record("성공해선 안 됨")
        } catch let f as EngineFailure {
            #expect(f.httpStatus == 400 && f.responseBody == "bad" && f.message == "HTTP 400")
        } catch { Issue.record("다른 오류") }
    }
}

struct ExplainToolsTests {
    @Test func submissionKeepsAtMostThreeDetails() {
        let s = ExplainTools.parseSubmission(["verdict": "정상", "identity": "i", "reason": "r", "details": ["1", "2", "3", "4", "5"]])
        #expect(s?.details == ["1", "2", "3"])
    }
}
