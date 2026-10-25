import Foundation

/// 호출 방식. 규칙이 종료 추천을 붙인 행은 데이터 손실 검사만 한다.
enum VerdictMode: String, Sendable, Equatable, Codable {
    case full
    case dataLossOnly
}

/// 엔진이 고른 판정. 정상은 태그 없음.
enum VerdictChoice: String, Sendable, Equatable {
    case terminate = "종료 추천"
    case attention = "관심 필요"
    case normal = "정상"

    var tag: UsageTag? {
        switch self {
        case .terminate: .terminate
        case .attention: .attention
        case .normal: nil
        }
    }
}

/// 엔진 한 번 호출의 결과. 기록용 원문(요청·응답 본문)을 함께 든다.
struct EngineReply: Sendable, Equatable {
    /// `.dataLossOnly` 에서는 nil
    var verdict: VerdictChoice?
    var confidence: Double?
    var probabilities: [String: Double]
    var dataLossProbability: Double?
    var inputTokens: Int
    var outputTokens: Int
    /// 응답이 알려준 모델 버전 (예 "jev-1.14.0")
    var model: String
    var requestBody: String
    var responseBody: String
    var httpStatus: Int
}

/// 엔진 호출 실패. 기록에 남길 요청·응답 원문을 함께 나른다.
struct EngineFailure: Error, Sendable, Equatable {
    var message: String
    var requestBody: String
    var responseBody: String?
    var httpStatus: Int?
}

/// 판정 엔진 공통 인터페이스. 규칙·캐시·상한·가리기·기록은 엔진 바깥에서 한다.
protocol VerdictEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// `state` 는 가린 뒤의 JSON 문자열. 실패하면 `EngineFailure` 를 던진다.
    func judge(state: String, mode: VerdictMode, apiKey: String) async throws -> EngineReply
    /// 키 연결 확인 — 가장 싼 호출 1회
    func validate(apiKey: String) async -> Bool
}

/// 엔진 레지스트리 (id → 엔진). 선택지를 늘리려면 `all` 에 추가한다.
enum VerdictEngines {
    static let defaultID = "jev"
    static let all: [any VerdictEngine] = [JEVEngine()]

    static func engine(id: String) -> (any VerdictEngine)? {
        all.first { $0.id == id }
    }
}
