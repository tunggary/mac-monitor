import Foundation

struct PolicyError: Error, Equatable {
    var message: String
}

struct CommandResult: Sendable, Equatable {
    var output: String
    var isError: Bool
}

protocol CommandRunning: Sendable {
    func run(command: String, args: [String]) async -> CommandResult
}

/// LLM 이 요청한 명령을 실행해도 되는지 검사한다 (순수). 읽기 전용·환경변수 비노출만 허용.
enum CommandPolicy {
    static let maxArgs = 24
    static let maxArgLength = 300

    /// 허용하면 실행할 argv (실행 파일 제외)를 돌려준다. docker stats 에는 `--no-stream` 이 붙는다.
    static func validate(command: String, args: [String]) -> Result<[String], PolicyError> {
        guard args.count <= maxArgs, args.allSatisfy({ $0.count <= maxArgLength && !$0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }) else {
            return .failure(PolicyError(message: "인자가 너무 많거나 길거나 제어 문자를 포함함"))
        }
        switch command {
        case "ps": return psCheck(args)
        case "lsof": return lsofCheck(args)
        case "pgrep": return .success(args)
        case "launchctl":
            // print 는 서비스 환경변수를 보여서 막는다
            guard args.first == "list" else {
                return .failure(PolicyError(message: "launchctl 은 list 만 허용됨"))
            }
            return .success(args)
        case "docker": return dockerCheck(args)
        default: return .failure(PolicyError(message: "허용되지 않는 명령: \(command)"))
        }
    }

    /// 값을 받는 ps 옵션 문자
    private static let psValueFlags: Set<Swift.Character> = ["o", "O", "p", "t", "U", "G"]

    private static func psCheck(_ args: [String]) -> Result<[String], PolicyError> {
        let denied = PolicyError(message: "ps 는 환경변수를 보이는 옵션(E, BSD 스타일 e)을 쓸 수 없음")
        var expectValue = false
        for arg in args {
            if expectValue { expectValue = false; continue }
            if arg.hasPrefix("--") { return .failure(PolicyError(message: "ps 긴 옵션은 허용되지 않음")) }
            let isDash = arg.hasPrefix("-")
            if !isDash, arg.allSatisfy({ $0.isNumber || $0 == "," }) { continue }
            let letters = Array(isDash ? arg.dropFirst() : Substring(arg))
            for (index, ch) in letters.enumerated() {
                if ch == "E" || (!isDash && ch == "e") { return .failure(denied) }
                if psValueFlags.contains(ch) {
                    if index == letters.count - 1 { expectValue = true }
                    break
                }
            }
        }
        return .success(args)
    }

    private static func lsofCheck(_ args: [String]) -> Result<[String], PolicyError> {
        for arg in args where arg.hasPrefix("-r") || arg.hasPrefix("+r") || arg.range(of: #"^[-+][A-Za-z]*r\d*$"#, options: .regularExpression) != nil {
            return .failure(PolicyError(message: "lsof 반복 모드(-r, +r)는 허용되지 않음"))
        }
        return .success(args)
    }

    private static func dockerCheck(_ args: [String]) -> Result<[String], PolicyError> {
        guard let sub = args.first else { return .failure(PolicyError(message: "docker 하위 명령이 필요함")) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "ps", "top":
            return .success(args)
        case "stats":
            return .success(rest.contains("--no-stream") ? args : args + ["--no-stream"])
        case "container", "compose":
            if rest.first == "ls" { return .success(args) }
        default: break
        }
        return .failure(PolicyError(message: "docker 는 ps, top, stats, container ls, compose ls 만 허용됨"))
    }
}

/// 정책을 통과한 명령을 셸 없이 `Process` 로 직접 실행한다.
struct SystemCommandRunner: CommandRunning {
    static let timeoutSeconds: TimeInterval = 5
    static let maxOutputBytes = 8 * 1024
    private static let maxReadBytes = 256 * 1024

    var home: String = NSHomeDirectory()

    static func executable(for command: String, home: String = NSHomeDirectory()) -> String? {
        switch command {
        case "ps": return "/bin/ps"
        case "lsof": return "/usr/sbin/lsof"
        case "pgrep": return "/usr/bin/pgrep"
        case "launchctl": return "/bin/launchctl"
        case "docker":
            return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.docker/bin/docker"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        default: return nil
        }
    }

    func run(command: String, args: [String]) async -> CommandResult {
        let argv: [String]
        switch CommandPolicy.validate(command: command, args: args) {
        case .failure(let error): return CommandResult(output: "거부됨: \(error.message)", isError: true)
        case .success(let value): argv = value
        }
        guard let path = Self.executable(for: command, home: home) else {
            return CommandResult(output: "\(command) 가 설치되어 있지 않음", isError: true)
        }
        let home = home
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.execute(path: path, argv: argv, home: home))
            }
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _timedOut = false
        var timedOut: Bool { lock.withLock { _timedOut } }
        func markTimedOut() { lock.withLock { _timedOut = true } }
    }

    private static func execute(path: String, argv: [String], home: String) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = argv
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return CommandResult(output: "실행 실패: \(error.localizedDescription)", isError: true)
        }
        let state = State()
        let timer = DispatchWorkItem { [process] in
            state.markTimedOut()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timer)

        var data = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count < maxReadBytes { data.append(chunk.prefix(maxReadBytes - data.count)) }
        }
        timer.cancel()
        process.waitUntilExit()

        var text = sanitize(String(decoding: data, as: UTF8.self), home: home)
        if state.timedOut { text += "\n(타임아웃: \(Int(timeoutSeconds))초 초과로 중단됨)" }
        let failed = state.timedOut || process.terminationStatus != 0
        return CommandResult(output: text, isError: failed)
    }

    /// 무작위 토큰과 홈 경로를 가리고 8KB 로 자른다.
    static func sanitize(_ text: String, home: String) -> String {
        let masked = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: " ", omittingEmptySubsequences: false)
                .map { Redactor.looksRandom(String($0)) ? Redactor.mask : String($0) }
                .joined(separator: " ")
        }.joined(separator: "\n")
        let redacted = Redactor.redactPaths(masked, home: home)
        guard redacted.utf8.count > maxOutputBytes else { return redacted }
        return String(decoding: Array(redacted.utf8.prefix(maxOutputBytes)), as: UTF8.self) + "…(잘림)"
    }
}
