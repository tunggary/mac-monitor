import Foundation
import Testing
@testable import MacMonitor

struct RedactorTests {
    let home = "/Users/me"

    @Test func homePathBecomesTilde() {
        #expect(Redactor.redactPaths("/Users/me/project/web", home: home) == "~/project/web")
        #expect(Redactor.redactPaths("/Users/me", home: home) == "~")
        #expect(Redactor.redactPaths("/Users/me2/x", home: home) == "/Users/me2/x")
        #expect(Redactor.redactPaths("/opt/homebrew/bin", home: home) == "/opt/homebrew/bin")
    }

    @Test func homePathInsideArguments() {
        let out = Redactor.redactArguments(["--config=/Users/me/app/cfg.json", "/Users/me/run.js"], home: home)
        #expect(out == ["--config=~/app/cfg.json", "~/run.js"])
    }

    @Test func namedSecretsAreMasked() {
        let args = ["--token=abc", "--api-key=xyz", "PASSWORD=hunter2", "--client_secret=s", "AUTH_HEADER=Bearer1"]
        #expect(Redactor.redactArguments(args, home: home) == ["--token=***", "--api-key=***", "PASSWORD=***", "--client_secret=***", "AUTH_HEADER=***"])
    }

    @Test func secretFlagMasksNextArgument() {
        #expect(Redactor.redactArguments(["--api-key", "abc123", "--port", "3000"], home: home) == ["--api-key", "***", "--port", "3000"])
        // 다음이 또 다른 옵션이면 가리지 않는다
        #expect(Redactor.redactArguments(["--token", "--verbose"], home: home) == ["--token", "--verbose"])
    }

    @Test func randomStringsAreMasked() {
        let randoms = [
            "sk-ant-api03-AbCdEfGh1234567890xyz",
            "ghp_1A2b3C4d5E6f7G8h9I0jKlMnOpQr",
            "deadbeefdeadbeefdeadbeef",
            "550e8400-e29b-41d4-a716-446655440000",
            "dGhpc2lzYXNlY3JldGtleTEyMw==",
        ]
        for value in randoms { #expect(Redactor.looksRandom(value), "\(value)") }
        #expect(Redactor.redactArguments(["--foo=" + randoms[2]], home: home) == ["--foo=***"])
    }

    @Test func pathsAndWordsAreKept() {
        let kept = [
            "next/dist/server/lib/start-server.js",
            "/opt/homebrew/opt/postgresql@16/bin/postgres",
            "com.apple.Virtualization.VirtualMachine",
            "internationalization",
            "next-dev-server-v2-production",
            "typescript-eslint-parser",
            "short",
            "한글로만이루어진아주긴문자열입니다만무작위가아님",
        ]
        for value in kept { #expect(!Redactor.looksRandom(value), "\(value)") }
        #expect(Redactor.redactArguments(["next", "dev", "-p", "3110"], home: home) == ["next", "dev", "-p", "3110"])
    }

    private func lines(_ s: UsageSignals) -> [String] {
        Redactor.stateText(s, home: home).split(separator: "\n").map(String.init)
    }

    @Test func stateTextRedactsAndKeepsFacts() {
        var s = makeSignals()
        s.executablePath = "/Users/me/.nvm/bin/node"
        s.cwd = "/Users/me/web"
        s.arguments = ["node", "/Users/me/web/node_modules/.bin/next", "dev", "--token=abc", "--turbo"]
        let text = Redactor.stateText(s, home: home)
        #expect(text.contains("- 대표 실행 명령: node next dev\n"))
        #expect(text.contains("- 작업 폴더: ~/web\n"))
        #expect(!text.contains("abc") && !text.contains("/Users/me") && !text.contains("--"))
        #expect(text.hasPrefix("- next-server (명령줄 도구), 프로세스 3개 (같은 이름 최대 3개).\n"))
    }

    @Test func commandDropsFlagsKeepsFilenamesAndMasksSecrets() {
        let cmd = { (args: [String]) in Redactor.summarizeCommand(path: "/usr/bin/tool", arguments: args, home: home) }
        #expect(cmd(["tool", "--type=renderer", "--lang=ko"]) == "tool")
        #expect(cmd(["tool", "a", "/x/y/b.js", "c", "d"]) == "tool a b.js c")
        #expect(cmd(["tool", "-D", "/opt/homebrew/var/pg"]) == "tool -D pg")
        #expect(cmd(["tool", "--api-key", "abc123", "run"]) == "tool *** run")
        #expect(cmd(["tool", "sk-ant-api03-AbCdEfGh1234567890xyz"]) == "tool ***")
        #expect(Redactor.summarizeCommand(path: nil, arguments: ["/bin/zsh", "-l"], home: home) == "zsh -l")
        #expect(Redactor.summarizeCommand(path: nil, arguments: [], home: home) == "")
    }

    @Test func stateTextOptionalLines() {
        var s = makeSignals(idle: 7200)
        s.cwd = "/"
        s.ports = []
        s.sameNameMaxCount = 1
        s.lostAncestor = nil
        s.isOrphan = false
        var l = lines(s)
        #expect(l[0] == "- next-server (명령줄 도구), 프로세스 3개.")
        #expect(!l.contains { $0.contains("작업 폴더") || $0.contains("띄운") || $0.contains("포트") || $0.contains("앞에") || $0.contains("창") || $0.contains("단조") })
        #expect(l.contains("- 2시간째 CPU 1% 미만·네트워크 연결 0개."))
        #expect(l.contains("- 실행된 지 24시간."))
        #expect(l.contains("- 메모리 0.9GB."))

        s.isOrphan = true
        #expect(lines(s).contains("- 이 프로세스를 띄운 부모 프로세스가 없음."))
        s.lostAncestor = "codex"
        l = lines(s)
        #expect(l.contains("- 이 프로세스를 띄운 codex 세션은 이미 종료됨."))
        #expect(!l.contains("- 이 프로세스를 띄운 부모 프로세스가 없음."))
        s.lostAncestor = "zsh"
        #expect(lines(s).contains("- 이 프로세스를 띄운 터미널 세션은 이미 종료됨."))
        s.isOrphan = false
        s.lostAncestor = nil
        s.liveAncestor = "cmux"
        #expect(lines(s).contains("- 이 프로세스를 띄운 터미널 세션이 살아 있음."))

        s.idleSeconds = 100
        s.cpuPercent = 3.04
        s.establishedConnections = 2
        s.ports = [3000, 3001]
        #expect(lines(s).contains("- 지금 CPU 3%, 네트워크 연결 2개."))
        #expect(lines(s).contains("- 열린 포트: 3000, 3001."))
        s.cpuPercent = 2.1
        #expect(lines(s).contains("- 지금 CPU 2.1%, 네트워크 연결 2개."))
    }

    @Test func stateTextGrowthAndActivity() {
        var s = makeSignals()
        s.footprintGrowthPercent = 9.9
        #expect(!lines(s).contains { $0.contains("최근 30분") })
        s.footprintGrowthPercent = 60.4
        #expect(lines(s).contains("- 최근 30분간 메모리 +60%."))
        s.footprintMonotonic = true
        #expect(lines(s).contains("- 최근 30분간 메모리 +60% (단조 증가)."))

        s.lastActiveSeconds = 300
        s.activeSinceMonitorStart = true
        s.hasVisibleWindow = false
        #expect(lines(s).suffix(2) == ["- 마지막으로 앞에 띄운 지 5분.", "- 보이는 창 없음."])
        s.activeSinceMonitorStart = false
        s.lastActiveSeconds = 10_800
        s.hasVisibleWindow = true
        #expect(lines(s).suffix(2) == ["- 3시간 넘게 앞에 띄운 적 없음.", "- 보이는 창 있음."])
    }

    @Test func durationFormat() {
        #expect(Redactor.duration(0) == "1분")
        #expect(Redactor.duration(59) == "1분")
        #expect(Redactor.duration(2_700) == "45분")
        #expect(Redactor.duration(3_600) == "1시간")
        #expect(Redactor.duration(3 * 3600 + 600) == "3시간 10분")
        #expect(Redactor.duration(2 * 86400 - 1) == "47시간 59분")
        #expect(Redactor.duration(2 * 86400) == "2일")
        #expect(Redactor.duration(9 * 86400 + 5000) == "9일")
    }
}
