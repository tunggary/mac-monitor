import Foundation

/// JEV (TypeSafe) 엔진 — POST /v1/systemone
struct JEVEngine: VerdictEngine {
    let id = "jev"
    let displayName = "JEV (TypeSafe)"

    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    static let timeout: TimeInterval = 10

    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func judge(state: String, mode: VerdictMode, apiKey: String) async throws -> EngineReply {
        let body = try Self.requestBody(state: state, mode: mode)
        let bodyText = String(decoding: body, as: UTF8.self)
        let (data, status): (Data, Int)
        do {
            (data, status) = try await send(body: body, apiKey: apiKey)
        } catch {
            let message = (error as? URLError)?.code == .timedOut ? "타임아웃" : error.localizedDescription
            throw EngineFailure(message: message, requestBody: bodyText, responseBody: nil, httpStatus: nil)
        }
        let responseText = String(decoding: data, as: UTF8.self)
        guard status == 200 else {
            throw EngineFailure(message: "HTTP \(status)", requestBody: bodyText, responseBody: responseText, httpStatus: status)
        }
        do {
            return try Self.parse(data: data, mode: mode, requestBody: bodyText, httpStatus: status)
        } catch {
            throw EngineFailure(message: "응답 해석 실패: \(error.localizedDescription)", requestBody: bodyText, responseBody: responseText, httpStatus: status)
        }
    }

    func validate(apiKey: String) async -> Bool {
        let object: [String: Any] = [
            "model": Self.model,
            "state": "ping",
            "questions": ["ping": ["type": "noul", "instructions": "Is this a ping?"]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: object),
              let (_, status) = try? await send(body: body, apiKey: apiKey) else { return false }
        return status == 200
    }

    private func send(body: Data, apiKey: String) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - 요청·응답 (순수)

    static var verdictQuestion: [String: Any] { [
        "type": "choice",
        "instructions": "A process group is using memory on a macOS developer's Mac. Based on the state, decide whether the user can safely terminate it to free memory. 이 프로세스 그룹을 종료해도 되는지 판단하라.",
        "criteria": [
            "종료 추천": "Safe to terminate: a leftover or orphaned dev server or tool whose launcher (terminal, agent, shell) is gone, idle with no connections for a long time. 띄운 쪽이 사라졌고 오래 한가해서 종료해도 되는 프로세스.",
            "관심 필요": "Worth the user's attention but not clearly safe to kill: unclear purpose, growing memory, or possibly still needed. 사용자가 직접 확인해볼 만한 프로세스.",
            "정상": "Normal: actively used, has live connections or CPU activity, or an app the user is working with. 지금 쓰이고 있는 정상 프로세스.",
        ],
    ] }

    static var dataLossQuestion: [String: Any] { [
        "type": "noul",
        "instructions": "Is this a process that would lose data or be hard to recover if terminated (e.g. a database, an editor with unsaved work, a running build or migration)? DB처럼 종료하면 데이터를 잃거나 복구가 어려운 프로세스인가?",
    ] }

    static func requestBody(state: String, mode: VerdictMode) throws -> Data {
        var questions: [String: Any] = ["data_loss": dataLossQuestion]
        if mode == .full { questions["verdict"] = verdictQuestion }
        let object: [String: Any] = ["model": model, "state": state, "questions": questions]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    struct ParseError: Error, LocalizedError {
        var errorDescription: String?
    }

    static func parse(data: Data, mode: VerdictMode, requestBody: String, httpStatus: Int) throws -> EngineReply {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else {
            throw ParseError(errorDescription: "answers 없음")
        }
        guard let loss = (answers["data_loss"] as? [String: Any])?["noul"] as? Double else {
            throw ParseError(errorDescription: "data_loss 없음")
        }
        var verdict: VerdictChoice?
        var confidence: Double?
        var probabilities: [String: Double] = [:]
        if mode == .full {
            guard let answer = answers["verdict"] as? [String: Any],
                  let choice = (answer["choice"] as? String).flatMap(VerdictChoice.init(rawValue:)),
                  let conf = answer["confidence"] as? Double else {
                throw ParseError(errorDescription: "verdict 없음")
            }
            verdict = choice
            confidence = conf
            probabilities = (answer["probabilities"] as? [String: Double]) ?? [:]
        }
        let usage = root["usage"] as? [String: Any]
        return EngineReply(
            verdict: verdict, confidence: confidence, probabilities: probabilities,
            dataLossProbability: loss,
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0,
            model: root["model"] as? String ?? model,
            requestBody: requestBody, responseBody: String(decoding: data, as: UTF8.self), httpStatus: httpStatus
        )
    }
}
