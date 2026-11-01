import Foundation
@testable import MacMonitor

/// 호출을 기록하고 정해진 결과를 돌려주는 가짜 명령 실행기
final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var result = CommandResult(output: "PID COMMAND\n1 launchd", isError: false)
    var calls: [String] { lock.withLock { _calls } }

    func run(command: String, args: [String]) async -> CommandResult {
        lock.withLock { _calls.append(ExplainTools.commandLine(command, args)) }
        return result
    }
}

/// 호출 횟수를 기록하는 가짜 제공자
final class FakeExplainProvider: ExplainProvider, @unchecked Sendable {
    let id = "fake"
    let displayName = "Fake"
    let model = "fake-1"
    private let lock = NSLock()
    private var _calls = 0
    private var _active = 0
    private var _maxActive = 0
    var delayMs = 0
    var reply: @Sendable () -> Result<ExplainReply, EngineFailure> = { .success(FakeExplainProvider.reply()) }

    var calls: Int { lock.withLock { _calls } }
    var maxActive: Int { lock.withLock { _maxActive } }

    static func reply(verdict: VerdictChoice = .normal) -> ExplainReply {
        ExplainReply(
            verdict: verdict, identity: "node 개발 서버", reason: "쓰이는 중", details: ["a"],
            inputTokens: 500, outputTokens: 80, model: "fake-1",
            requestBody: "{\"req\":1}", responseBody: "{\"res\":1}", httpStatus: 200, commands: ["ps -p 1"]
        )
    }

    func explain(context: String, runner: any CommandRunning, apiKey: String) async throws -> ExplainReply {
        lock.withLock { _calls += 1; _active += 1; _maxActive = max(_maxActive, _active) }
        defer { lock.withLock { _active -= 1 } }
        if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
        switch reply() {
        case .success(let r): return r
        case .failure(let f): throw f
        }
    }

    func validate(apiKey: String) async -> Bool { true }
}

/// 엔드포인트 host 별로 응답을 돌려주는 URLProtocol 목. 테스트마다 고유 host 를 쓰면 병렬 실행해도 섞이지 않는다.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (_ request: URLRequest, _ body: Data) -> (status: Int, body: Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) { lock.withLock { handlers[host] = handler } }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func uniqueEndpoint(path: String) -> URL {
        URL(string: "https://stub-\(UUID().uuidString.lowercased()).test\(path)")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let handler = Self.lock.withLock { Self.handlers[request.url?.host ?? ""] }
        let (status, data) = handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 응답을 순서대로 돌려주고 받은 요청 본문을 기록한다.
final class ScriptedServer: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data]
    private var _bodies: [[String: Any]] = []
    private var _headers: [[String: String]] = []
    var bodies: [[String: Any]] { lock.withLock { _bodies } }
    var headers: [[String: String]] { lock.withLock { _headers } }

    init(_ responses: [String]) { queue = responses.map { Data($0.utf8) } }

    func serve(host: String) {
        StubURLProtocol.register(host: host) { [self] request, body in
            lock.withLock {
                _bodies.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
                _headers.append(request.allHTTPHeaderFields ?? [:])
                return (200, queue.isEmpty ? Data("{}".utf8) : queue.removeFirst())
            }
        }
    }
}
