import Foundation
import Testing
@testable import MacMonitor

/// 실제 자식 프로세스를 띄워 신호가 전달되는지 확인한다. 내 앱·사용자 앱은 건드리지 않는다.
@Suite(.serialized)
struct ProcessKillerTests {
    private func spawn(_ path: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        return process
    }

    /// 최대 `seconds` 동안 조건을 기다린다.
    private func wait(seconds: Double = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func sigtermKillsSleep() async throws {
        let process = try spawn("/bin/sleep", ["60"])
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let ids = ProcessKiller.identities(of: [process.processIdentifier])
        #expect(ids.count == 1)
        #expect(ids[0].isAlive)

        #expect(ProcessKiller.send(SIGTERM, to: ids) == 1)
        let died = await wait { !ids[0].isAlive }
        #expect(died)
        #expect(ProcessKiller.alive(ids).isEmpty)
    }

    @Test func sigtermIgnoredThenSigkillKills() async throws {
        let process = try spawn("/bin/sh", ["-c", "trap \"\" TERM; sleep 60"])
        let shell = process.processIdentifier
        defer {
            _ = try? spawn("/usr/bin/pkill", ["-KILL", "-P", "\(shell)"]).waitUntilExit()
            if process.isRunning { kill(shell, SIGKILL) }
        }
        try await Task.sleep(for: .milliseconds(300)) // trap 이 걸릴 시간
        let ids = ProcessKiller.identities(of: [shell])
        #expect(ids.count == 1)

        ProcessKiller.terminate(ids)
        try await Task.sleep(for: .milliseconds(500))
        let survivors = ProcessKiller.alive(ids)
        #expect(survivors == ids) // SIGTERM 을 무시했다

        ProcessKiller.forceKill(survivors)
        let died = await wait { ProcessKiller.alive(ids).isEmpty }
        #expect(died)
    }

    @Test func staleIdentityIsNotSignalled() async throws {
        let process = try spawn("/bin/sleep", ["60"])
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let real = try #require(ProcessIdentity.current(process.processIdentifier))
        // 시작시간이 다른 신원 = pid 가 재사용된 다른 프로세스
        let stale = ProcessIdentity(pid: real.pid, startSeconds: real.startSeconds &- 1000, startMicroseconds: real.startMicroseconds)
        #expect(ProcessKiller.send(SIGKILL, to: [stale]) == 0)
        #expect(!stale.isAlive)
        #expect(real.isAlive)
    }

    @Test func missingPidHasNoIdentity() {
        #expect(ProcessIdentity.current(Int32.max) == nil)
        #expect(ProcessKiller.identities(of: [Int32.max]).isEmpty)
    }

    @MainActor
    @Test func coordinatorShowsConfirmOnlyForSurvivors() async throws {
        let stubborn = try spawn("/bin/sh", ["-c", "trap \"\" TERM; sleep 60"])
        let polite = try spawn("/bin/sleep", ["60"])
        let shell = stubborn.processIdentifier
        defer {
            _ = try? spawn("/usr/bin/pkill", ["-KILL", "-P", "\(shell)"]).waitUntilExit()
            kill(shell, SIGKILL)
            kill(polite.processIdentifier, SIGKILL)
        }
        try await Task.sleep(for: .milliseconds(300))

        let coordinator = KillCoordinator(grace: .milliseconds(400))
        var shownFor: String?
        coordinator.onConfirmShown = { shownFor = $0 }
        coordinator.terminate(key: "polite", groupID: "p", name: "polite", pids: [polite.processIdentifier])
        coordinator.terminate(key: "stubborn", groupID: "s", name: "stubborn", pids: [shell])
        #expect(coordinator.entries["stubborn"]?.needsConfirm == false)

        try await Task.sleep(for: .milliseconds(1200))
        #expect(coordinator.entries["polite"] == nil) // 죽었으니 기록도 없다
        #expect(coordinator.entries["stubborn"]?.needsConfirm == true)
        #expect(shownFor == "s")

        coordinator.forceKill(key: "stubborn")
        #expect(coordinator.entries["stubborn"] == nil)
        var gone = false
        for _ in 0..<100 where !gone {
            gone = ProcessKiller.identities(of: [shell]).isEmpty
            if !gone { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(gone)
    }

    @MainActor
    @Test func alertStyleTerminateShowsConfirmForSurvivorInPresentGroup() async throws {
        let stubborn = try spawn("/bin/sh", ["-c", "trap \"\" TERM; sleep 60"])
        let shell = stubborn.processIdentifier
        defer {
            _ = try? spawn("/usr/bin/pkill", ["-KILL", "-P", "\(shell)"]).waitUntilExit()
            kill(shell, SIGKILL)
        }
        try await Task.sleep(for: .milliseconds(300))
        let targets = ProcessKiller.identities(of: [shell])

        let coordinator = KillCoordinator(grace: .milliseconds(300))
        var shownFor: String?
        coordinator.onConfirmShown = { shownFor = $0 }
        coordinator.groupExists = { $0 == "g" }
        let key = KillCoordinator.groupKey("g")
        coordinator.terminate(key: key, groupID: "g", name: "g", targets: targets)
        try await Task.sleep(for: .milliseconds(900))
        #expect(shownFor == "g")
        #expect(coordinator.entries[key]?.survivors == targets)
        // 자동 SIGKILL 은 없다
        #expect(ProcessKiller.alive(targets) == targets)
    }

    @MainActor
    @Test func vanishedGroupEndsWithoutConfirm() async throws {
        let stubborn = try spawn("/bin/sh", ["-c", "trap \"\" TERM; sleep 60"])
        let shell = stubborn.processIdentifier
        defer {
            _ = try? spawn("/usr/bin/pkill", ["-KILL", "-P", "\(shell)"]).waitUntilExit()
            kill(shell, SIGKILL)
        }
        try await Task.sleep(for: .milliseconds(300))

        let coordinator = KillCoordinator(grace: .milliseconds(300))
        var shown = false
        coordinator.onConfirmShown = { _ in shown = true }
        coordinator.groupExists = { _ in false }
        let key = KillCoordinator.groupKey("gone")
        coordinator.terminate(key: key, groupID: "gone", name: "gone", targets: ProcessKiller.identities(of: [shell]))
        try await Task.sleep(for: .milliseconds(900))
        #expect(!shown)
        #expect(coordinator.entries[key] == nil)
    }
}
