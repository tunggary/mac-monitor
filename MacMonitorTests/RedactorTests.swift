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

    @Test func stateJSONIsSortedAndRedacted() {
        var s = makeSignals()
        s.executablePath = "/Users/me/.nvm/bin/node"
        s.cwd = "/Users/me/web"
        s.arguments = ["--token=abc", "dev"]
        let json = Redactor.stateJSON(s, home: home)
        #expect(json.contains("\"cwd\":\"~/web\""))
        #expect(json.contains("\"executable\":\"~/.nvm/bin/node\""))
        #expect(json.contains("\"--token=***\""))
        #expect(!json.contains("abc"))
        #expect(!json.contains("/Users/me"))
        #expect(json.range(of: "\"arguments\"")!.lowerBound < json.range(of: "\"cwd\"")!.lowerBound)
        #expect(json.contains("\"footprintMB\":953"))
    }
}
