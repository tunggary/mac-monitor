import Foundation
import Testing
@testable import MacMonitor

struct JEVEngineTests {
    // 실측 응답 (2026-10-24, 키 없음)
    static let fullResponse = """
    {"model":"jev-1.14.0","answers":{"verdict":{"type":"choice","choice":"종료 추천","confidence":0.95,"probabilities":{"종료 추천":0.97,"관심 필요":0.03,"정상":0.0}},"data_loss":{"type":"noul","noul":0.2}},"usage":{"input_tokens":727,"output_tokens":64}}
    """
    static let lossResponse = """
    {"model":"jev-1.14.0","answers":{"data_loss":{"type":"noul","noul":0.8}},"usage":{"input_tokens":500,"output_tokens":20}}
    """

    @Test func fullRequestHasBothQuestions() throws {
        let body = try JEVEngine.requestBody(state: "{\"a\":1}", mode: .full)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["model"] as? String == "jev-latest")
        #expect(root["state"] as? String == "{\"a\":1}")
        let questions = try #require(root["questions"] as? [String: Any])
        #expect(Set(questions.keys) == ["verdict", "data_loss"])
        let verdict = try #require(questions["verdict"] as? [String: Any])
        #expect(verdict["type"] as? String == "choice")
        let criteria = try #require(verdict["criteria"] as? [String: String])
        #expect(Set(criteria.keys) == ["종료 추천", "관심 필요", "정상"])
        #expect((questions["data_loss"] as? [String: Any])?["type"] as? String == "noul")
    }

    @Test func dataLossOnlyRequestHasOneQuestion() throws {
        let body = try JEVEngine.requestBody(state: "s", mode: .dataLossOnly)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set((root["questions"] as? [String: Any] ?? [:]).keys) == ["data_loss"])
    }

    @Test func requestNeverContainsKey() throws {
        let text = String(decoding: try JEVEngine.requestBody(state: "s", mode: .full), as: UTF8.self)
        #expect(!text.contains("Bearer") && !text.contains("apikey"))
    }

    @Test func parsesFullResponse() throws {
        let reply = try JEVEngine.parse(data: Data(Self.fullResponse.utf8), mode: .full, requestBody: "req", httpStatus: 200)
        #expect(reply.verdict == .terminate)
        #expect(reply.confidence == 0.95)
        #expect(reply.probabilities["관심 필요"] == 0.03)
        #expect(reply.dataLossProbability == 0.2)
        #expect(reply.inputTokens == 727 && reply.outputTokens == 64)
        #expect(reply.model == "jev-1.14.0")
        #expect(reply.responseBody == Self.fullResponse)
    }

    @Test func parsesDataLossOnlyResponse() throws {
        let reply = try JEVEngine.parse(data: Data(Self.lossResponse.utf8), mode: .dataLossOnly, requestBody: "req", httpStatus: 200)
        #expect(reply.verdict == nil && reply.confidence == nil)
        #expect(reply.dataLossProbability == 0.8)
    }

    @Test func malformedResponsesThrow() {
        #expect(throws: (any Error).self) { try JEVEngine.parse(data: Data("{}".utf8), mode: .full, requestBody: "", httpStatus: 200) }
        #expect(throws: (any Error).self) { try JEVEngine.parse(data: Data(Self.lossResponse.utf8), mode: .full, requestBody: "", httpStatus: 200) }
    }

    @Test func registryFindsJEV() {
        #expect(VerdictEngines.engine(id: "jev")?.displayName == "JEV (TypeSafe)")
        #expect(VerdictEngines.engine(id: "nope") == nil)
    }
}
