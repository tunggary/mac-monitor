import Foundation
import Testing
@testable import MacMonitor

struct CommandPolicyTests {
    private func allowed(_ c: String, _ a: [String]) -> [String]? {
        if case .success(let v) = CommandPolicy.validate(command: c, args: a) { return v }
        return nil
    }

    @Test func psAllowsPlainListings() {
        #expect(allowed("ps", ["-axo", "pid,command"]) != nil)
        #expect(allowed("ps", ["-o", "pid,ppid,etime,rss,command", "-p", "123,456"]) != nil)
        #expect(allowed("ps", ["-e"]) != nil)
        #expect(allowed("ps", ["aux"]) != nil)
        #expect(allowed("ps", ["-p", "123", "456"]) != nil)
    }

    @Test func psDeniesEnvironmentFlags() {
        #expect(allowed("ps", ["eww"]) == nil)
        #expect(allowed("ps", ["auxe"]) == nil)
        #expect(allowed("ps", ["-E"]) == nil)
        #expect(allowed("ps", ["-axE"]) == nil)
        #expect(allowed("ps", ["-p", "1", "eww"]) == nil)
    }

    @Test func lsof() {
        #expect(allowed("lsof", ["-p", "123"]) != nil)
        #expect(allowed("lsof", ["-r", "1"]) == nil)
        #expect(allowed("lsof", ["+r1"]) == nil)
        #expect(allowed("lsof", ["-nPr"]) == nil)
        #expect(allowed("lsof", ["-iTCP", "-sTCP:LISTEN"]) != nil)
    }

    @Test func docker() {
        #expect(allowed("docker", ["ps", "-a"]) == ["ps", "-a"])
        #expect(allowed("docker", ["stats"]) == ["stats", "--no-stream"])
        #expect(allowed("docker", ["stats", "--no-stream"]) == ["stats", "--no-stream"])
        #expect(allowed("docker", ["top", "abc"]) != nil)
        #expect(allowed("docker", ["container", "ls"]) != nil)
        #expect(allowed("docker", ["compose", "ls"]) != nil)
        for sub in ["inspect", "exec", "logs", "rm", "stop", "run"] {
            #expect(allowed("docker", [sub, "abc"]) == nil)
        }
        #expect(allowed("docker", ["container", "rm", "x"]) == nil)
        #expect(allowed("docker", ["-H", "tcp://x", "ps"]) == nil)
        #expect(allowed("docker", []) == nil)
    }

    @Test func launchctlAndOthers() {
        #expect(allowed("launchctl", ["list"]) != nil)
        #expect(allowed("launchctl", ["print", "gui/501"]) == nil)
        #expect(allowed("launchctl", ["kill", "9", "x"]) == nil)
        #expect(allowed("launchctl", []) == nil)
        #expect(allowed("pgrep", ["-fl", "node"]) != nil)
        for c in ["rm", "cat", "sh", "kill", "env"] { #expect(allowed(c, ["x"]) == nil) }
    }

    @Test func rejectsControlCharacters() {
        #expect(allowed("pgrep", ["a\u{0}b"]) == nil)
        #expect(allowed("pgrep", ["a\nb"]) == nil)
    }

    @Test func sanitizeMasksRandomTokensPathsAndTruncates() {
        let out = SystemCommandRunner.sanitize("run /Users/me/app Ab3dEf9hIj1kLm4nOp5qRs\nok", home: "/Users/me")
        #expect(out == "run ~/app ***\nok")
        let long = SystemCommandRunner.sanitize(String(repeating: "a ", count: 10_000), home: "/Users/me")
        #expect(long.hasSuffix("…(잘림)") && long.utf8.count < 8_300)
    }

    @Test func runnerRejectsDeniedAndRunsAllowed() async {
        let runner = SystemCommandRunner()
        let denied = await runner.run(command: "ps", args: ["eww"])
        #expect(denied.isError && denied.output.hasPrefix("거부됨"))
        let ok = await runner.run(command: "ps", args: ["-p", "1", "-o", "pid"])
        #expect(!ok.isError && ok.output.contains("PID"))
    }
}
