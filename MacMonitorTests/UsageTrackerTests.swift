import Foundation
import Testing
@testable import MacMonitor

struct UsageTrackerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let cmuxPath = "/Applications/cmux.app/Contents/MacOS/cmux"

    private func group(_ id: String, kind: GroupKind = .cli, _ samples: [ProcessSample]) -> AppGroup {
        AppGroup(
            id: id, kind: kind, displayName: id, bundlePath: nil, processCount: samples.count,
            footprint: samples.reduce(0) { $0 + ($1.footprint ?? 0) },
            cpuPercent: samples.reduce(0) { $0 + $1.cpuPercent }, cwdFolder: nil,
            ports: Array(Set(samples.flatMap(\.listenPorts))).sorted(), pids: samples.map(\.pid).sorted(),
            subgroups: [], terminablePids: []
        )
    }

    private func proc(_ pid: Int32, ppid: Int32 = 1, name: String = "node", path: String? = "/opt/homebrew/bin/node",
                      footprint: UInt64 = 100, cpu: Double = 0, established: Int = 0, start: Date? = nil) -> ProcessSample {
        ProcessSample(pid: pid, ppid: ppid, name: name, path: path, footprint: footprint, cpuPercent: cpu,
                      startDate: start ?? t0, establishedConnections: established)
    }

    private func run(_ tracker: UsageTracker, _ samples: [ProcessSample], at offset: TimeInterval, id: String = "g") -> UsageSignals? {
        tracker.update(samples: samples, groups: [group(id, samples)], now: t0.addingTimeInterval(offset))[id]
    }

    // MARK: idle

    @Test func idleStartsAndResets() {
        let tracker = UsageTracker()
        let idle = [proc(10)]
        #expect(run(tracker, idle, at: 0)?.idleSeconds == 0)
        #expect(run(tracker, idle, at: 600)?.idleSeconds == 600)
        #expect(run(tracker, [proc(10, cpu: 5)], at: 603)?.idleSeconds == 0)
        #expect(run(tracker, idle, at: 700)?.idleSeconds == 0)
        #expect(run(tracker, idle, at: 760)?.idleSeconds == 60)
    }

    @Test func connectionsBreakIdle() {
        let tracker = UsageTracker()
        _ = run(tracker, [proc(10)], at: 0)
        let signals = run(tracker, [proc(10, established: 2)], at: 100)
        #expect(signals?.idleSeconds == 0)
        #expect(signals?.establishedConnections == 2)
    }

    // MARK: footprint

    @Test func growthNeedsThirtyMinutesOfHistory() {
        let tracker = UsageTracker()
        var last: UsageSignals?
        for minute in 0...29 { last = run(tracker, [proc(10, footprint: UInt64(100 + minute))], at: Double(minute) * 60) }
        #expect(last?.footprintGrowthPercent == nil)
        last = run(tracker, [proc(10, footprint: 160)], at: 30 * 60)
        #expect(last?.footprintGrowthPercent == 60)
        #expect(last?.footprintMonotonic == true)
    }

    @Test func dipBreaksMonotonic() {
        let tracker = UsageTracker()
        var last: UsageSignals?
        for minute in 0...30 {
            let value: UInt64 = minute == 15 ? 90 : 100 + UInt64(minute) * 3
            last = run(tracker, [proc(10, footprint: value)], at: Double(minute) * 60)
        }
        #expect(last?.footprintGrowthPercent != nil)
        #expect(last?.footprintMonotonic == false)
    }

    @Test func smallDipStillMonotonic() {
        let tracker = UsageTracker()
        var last: UsageSignals?
        for minute in 0...30 {
            // 15분에 직전(145) 대비 약 3% 감소 → 출렁임으로 본다
            let value: UInt64 = minute == 15 ? 141 : 100 + UInt64(minute) * 3
            last = run(tracker, [proc(10, footprint: value)], at: Double(minute) * 60)
        }
        #expect(last?.footprintMonotonic == true)
    }

    @Test func historyIsTrimmed() {
        let tracker = UsageTracker()
        for minute in 0...120 { _ = run(tracker, [proc(10, footprint: 100)], at: Double(minute) * 60) }
        let last = run(tracker, [proc(10, footprint: 150)], at: 121 * 60)
        #expect(last?.footprintGrowthPercent == 50)
    }

    // MARK: 고아

    @Test func lostAncestorMakesOrphan() {
        let tracker = UsageTracker()
        let parent = proc(5, name: "codex", path: "/usr/local/bin/codex")
        let child = proc(10, ppid: 5)
        let before = tracker.update(samples: [parent, child], groups: [group("g", [child])], now: t0)["g"]
        #expect(before?.isOrphan == false)
        let after = run(tracker, [proc(10, ppid: 1)], at: 3)
        #expect(after?.isOrphan == true)
        #expect(after?.lostAncestor == "codex")
    }

    @Test func agentAncestorWinsOverShellAndVersionNameIsResolved() {
        let tracker = UsageTracker()
        // Claude Code: 프로세스 이름이 버전 문자열, Bash 도구는 zsh -c 를 거친다
        let claude = proc(5, ppid: 3, name: "2.1.302", path: "/Users/u/.local/share/claude/versions/2.1.302")
        let shell = proc(6, ppid: 5, name: "zsh", path: "/bin/zsh")
        let child = proc(10, ppid: 6)
        _ = tracker.update(samples: [claude, shell, child], groups: [group("g", [child])], now: t0)
        let after = run(tracker, [proc(10, ppid: 1)], at: 3)
        #expect(after?.lostAncestor == "claude")
    }

    @Test func ancestorFoundThroughIntermediateProcess() {
        let tracker = UsageTracker()
        let terminal = proc(2, name: "cmux", path: cmuxPath)
        let shell = proc(3, ppid: 2, name: "zsh", path: "/bin/zsh")
        let mid = proc(4, ppid: 3, name: "npm", path: "/opt/homebrew/bin/npm")
        let child = proc(10, ppid: 4)
        _ = tracker.update(samples: [terminal, shell, mid, child], groups: [group("g", [child])], now: t0)
        let after = run(tracker, [proc(10, ppid: 1)], at: 3)
        #expect(after?.lostAncestor == "zsh") // 가장 가까운 조상
    }

    @Test func launchdChildFromStartIsOrphanWithoutAncestor() {
        let tracker = UsageTracker()
        let signals = run(tracker, [proc(10)], at: 0)
        #expect(signals?.isOrphan == true)
        #expect(signals?.lostAncestor == nil)
    }

    @Test func bundledProcessIsNotOrphanByRuleB() {
        let tracker = UsageTracker()
        let helper = proc(10, name: "Helper", path: "/Applications/X.app/Contents/MacOS/Helper")
        #expect(run(tracker, [helper], at: 0)?.isOrphan == false)
    }

    @Test func unrecognizedParentThatDiesIsNotOrphan() {
        let tracker = UsageTracker()
        let parent = proc(5, name: "make", path: "/usr/bin/make")
        let child = proc(10, ppid: 5)
        _ = tracker.update(samples: [parent, child], groups: [group("g", [child])], now: t0)
        #expect(run(tracker, [proc(10, ppid: 1)], at: 3)?.isOrphan == false)
    }

    @Test func allMembersMustBeOrphan() {
        let tracker = UsageTracker()
        let terminal = proc(2, name: "cmux", path: cmuxPath)
        let attached = proc(11, ppid: 2)
        let orphan = proc(10)
        let result = tracker.update(samples: [terminal, attached, orphan], groups: [group("g", [attached, orphan])], now: t0)
        #expect(result["g"]?.isOrphan == false)
    }

    @Test func appGroupIsNeverOrphan() {
        let tracker = UsageTracker()
        let sample = proc(10)
        let result = tracker.update(samples: [sample], groups: [group("g", kind: .app, [sample])], now: t0)
        #expect(result["g"]?.isOrphan == false)
    }

    @Test func pidReuseStartsFresh() {
        let tracker = UsageTracker()
        let parent = proc(5, name: "claude", path: "/x/claude")
        let first = proc(10, ppid: 5, start: t0)
        _ = tracker.update(samples: [parent, first], groups: [group("g", [first])], now: t0)
        // 같은 pid, 다른 시작 시각: 이전 조상 기억을 물려받지 않는다. 처음부터 launchd 라면 (b) 고아.
        let reused = proc(10, ppid: 1, start: t0.addingTimeInterval(100))
        let signals = run(tracker, [reused], at: 200)
        #expect(signals?.isOrphan == true)
        #expect(signals?.lostAncestor == nil)
    }

    // MARK: 살아 있는 조상

    @Test func liveAncestorIsAgentOverShell() {
        let tracker = UsageTracker()
        let claude = proc(5, ppid: 3, name: "2.1.302", path: "/Users/u/.local/share/claude/versions/2.1.302")
        let shell = proc(6, ppid: 5, name: "zsh", path: "/bin/zsh")
        let child = proc(10, ppid: 6)
        let signals = tracker.update(samples: [claude, shell, child], groups: [group("g", [child])], now: t0)["g"]
        #expect(signals?.isOrphan == false)
        #expect(signals?.liveAncestor == "claude")
    }

    @Test func liveAncestorFallsBackToNearestShell() {
        let tracker = UsageTracker()
        let terminal = proc(2, name: "cmux", path: cmuxPath)
        let shell = proc(3, ppid: 2, name: "zsh", path: "/bin/zsh")
        let child = proc(10, ppid: 3)
        #expect(tracker.update(samples: [terminal, shell, child], groups: [group("g", [child])], now: t0)["g"]?.liveAncestor == "zsh")
    }

    @Test func orphanAndAppGroupsHaveNoLiveAncestor() {
        let tracker = UsageTracker()
        #expect(run(tracker, [proc(10)], at: 0)?.liveAncestor == nil)
        let parent = proc(5, name: "claude", path: "/x/claude")
        let child = proc(11, ppid: 5)
        let result = tracker.update(samples: [parent, child], groups: [group("a", kind: .app, [child])], now: t0)
        #expect(result["a"]?.liveAncestor == nil)
    }

    @Test func liveAncestorClearsAfterParentDies() {
        let tracker = UsageTracker()
        let parent = proc(5, name: "codex", path: "/usr/local/bin/codex")
        let child = proc(10, ppid: 5)
        #expect(tracker.update(samples: [parent, child], groups: [group("g", [child])], now: t0)["g"]?.liveAncestor == "codex")
        let after = run(tracker, [proc(10, ppid: 1)], at: 3)
        #expect(after?.liveAncestor == nil)
        #expect(after?.lostAncestor == "codex")
    }

    // MARK: 대표값·정리

    @Test func representativeAndCounts() {
        let tracker = UsageTracker()
        let small = ProcessSample(pid: 10, name: "node", path: "/a", cwd: "/w/a", footprint: 10, startDate: t0.addingTimeInterval(-100), arguments: ["a"])
        let big = ProcessSample(pid: 11, name: "node", path: "/b", cwd: "/w/b", footprint: 50, startDate: t0.addingTimeInterval(-500), arguments: ["b"])
        let other = ProcessSample(pid: 12, name: "esbuild", path: "/c", footprint: 5, startDate: t0)
        let signals = tracker.update(samples: [small, big, other], groups: [group("g", [small, big, other])], now: t0)["g"]
        #expect(signals?.executablePath == "/b")
        #expect(signals?.arguments == ["b"])
        #expect(signals?.cwd == "/w/b")
        #expect(signals?.uptimeSeconds == 500)
        #expect(signals?.sameNameMaxCount == 2)
        #expect(signals?.processCount == 3)
    }

    @Test func vanishedGroupStateIsDropped() {
        let tracker = UsageTracker()
        _ = run(tracker, [proc(10)], at: 0)
        _ = tracker.update(samples: [], groups: [], now: t0.addingTimeInterval(600))
        #expect(run(tracker, [proc(10)], at: 1200)?.idleSeconds == 0)
    }
}
