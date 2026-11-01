import Foundation

/// 설명 제공자 한 번 호출의 결과. 기록용 원문(요청·응답 본문)과 실행한 명령을 함께 든다.
struct ExplainReply: Sendable, Equatable {
    var verdict: VerdictChoice
    var identity: String
    var reason: String
    var details: [String]
    var inputTokens: Int
    var outputTokens: Int
    var model: String
    /// 마지막 요청 본문 (그때까지의 전체 대화를 담고 있다)
    var requestBody: String
    var responseBody: String
    var httpStatus: Int
    /// LLM 이 실행한 명령 기록 ("ps -o pid,command -p 123")
    var commands: [String]
}

/// 행에 표시할 AI 설명
struct AIExplanation: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case ok
        case failed(String)
    }

    var status: Status
    var verdict: VerdictChoice?
    var identity: String
    var reason: String
    var details: [String]
    var providerName: String
    /// 설명을 요청했을 당시의 배지
    var inputTag: UsageTag
}

/// LLM 이 읽기 전용 명령으로 조사해 그룹을 설명하는 제공자. 실패하면 `EngineFailure` 를 던진다.
protocol ExplainProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var model: String { get }
    /// `context` 는 가린 뒤의 그룹 설명 문장. 명령 실행은 `runner` 가 한다.
    func explain(context: String, runner: any CommandRunning, apiKey: String) async throws -> ExplainReply
    /// 키 연결 확인 — 가장 싼 호출 1회
    func validate(apiKey: String) async -> Bool
}

/// 제공자 레지스트리 (id → 제공자). 선택지를 늘리려면 `all` 에 추가한다.
enum ExplainProviders {
    static let defaultID = "claude"
    static let all: [any ExplainProvider] = [ClaudeExplainer(), OpenAIExplainer()]

    static func provider(id: String) -> (any ExplainProvider)? {
        all.first { $0.id == id }
    }
}
