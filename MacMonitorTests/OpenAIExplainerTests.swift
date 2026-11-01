import Foundation
import Testing
@testable import MacMonitor

struct OpenAIExplainerTests {
    private func response(_ output: String, status: String = "completed") -> String {
        "{\"status\":\"\(status)\",\"model\":\"gpt-6-astra\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20},\"output\":\(output)}"
    }

    private let submitItem = """
    [{"type":"function_call","id":"fc2","call_id":"c2","name":"submit_explanation","arguments":"{\\"verdict\\":\\"관심 필요\\",\\"identity\\":\\"DB\\",\\"reason\\":\\"데이터 보유\\",\\"details\\":[]}"}]
    """
    private let commandItems = """
    [{"type":"reasoning","id":"rs1","summary":[],"encrypted_content":"enc"},{"type":"function_call","id":"fc1","call_id":"c1","name":"run_command","arguments":"{\\"command\\":\\"ps\\",\\"args\\":[\\"-p\\",\\"1\\"]}"}]
    """

    @Test func requestBodyShape() throws {
        let data = try OpenAIExplainer.requestBody(model: "gpt-6-luna", input: [["role": "user", "content": "hi"]])
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["store"] as? Bool == false && obj["previous_response_id"] == nil)
        #expect(obj["instructions"] as? String == ExplainPrompt.systemPrompt)
        let tools = try #require(obj["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["run_command", "submit_explanation"])
        #expect(tools.allSatisfy { $0["type"] as? String == "function" && $0["strict"] as? Bool == true && $0["parameters"] != nil })
    }

    @Test func parseSubmit() throws {
        let r = try OpenAIExplainer.parse(data: Data(response(submitItem).utf8))
        guard case .submit(let s) = OpenAIExplainer.interpret(r) else { Issue.record("submit 아님"); return }
        #expect(s.verdict == .attention && s.identity == "DB" && s.details.isEmpty)
        #expect(r.inputTokens == 100 && r.outputTokens == 20)
    }

    @Test func parseFunctionCall() throws {
        let r = try OpenAIExplainer.parse(data: Data(response(commandItems).utf8))
        guard case .calls(let calls) = OpenAIExplainer.interpret(r) else { Issue.record("calls 아님"); return }
        #expect(calls.count == 1 && calls[0].callID == "c1" && calls[0].arguments["command"] as? String == "ps")
        #expect(r.output.count == 2)
    }

    @Test func refusalAndIncompleteFail() throws {
        let refusal = response("[{\"type\":\"message\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"no\"}]}]")
        guard case .failure = OpenAIExplainer.interpret(try OpenAIExplainer.parse(data: Data(refusal.utf8))) else { Issue.record("refusal"); return }
        let incomplete = "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[]}"
        guard case .failure = OpenAIExplainer.interpret(try OpenAIExplainer.parse(data: Data(incomplete.utf8))) else { Issue.record("incomplete"); return }
    }

    @Test func noCalls() throws {
        let r = try OpenAIExplainer.parse(data: Data(response("[{\"type\":\"message\",\"content\":[]}]").utf8))
        guard case .noCalls = OpenAIExplainer.interpret(r) else { Issue.record("noCalls 아님"); return }
    }

    @Test func twoRoundTripLoop() async throws {
        let endpoint = StubURLProtocol.uniqueEndpoint(path: "/v1/responses")
        let server = ScriptedServer([response(commandItems), response(submitItem)])
        server.serve(host: endpoint.host!)
        let runner = FakeRunner()
        let explainer = OpenAIExplainer(session: StubURLProtocol.makeSession(), endpoint: endpoint)
        let reply = try await explainer.explain(context: "ctx", runner: runner, apiKey: "K")
        #expect(reply.verdict == .attention && reply.commands == ["ps -p 1"] && runner.calls == ["ps -p 1"])
        #expect(reply.inputTokens == 200)
        #expect(server.headers[0]["Authorization"] == "Bearer K")
        // 두 번째 요청 input: user + reasoning + function_call + function_call_output
        let input = try #require(server.bodies[1]["input"] as? [[String: Any]])
        #expect(input.count == 4)
        #expect(input[1]["type"] as? String == "reasoning" && input[1]["encrypted_content"] as? String == "enc")
        #expect(input[3]["type"] as? String == "function_call_output" && input[3]["call_id"] as? String == "c1")
    }
}
