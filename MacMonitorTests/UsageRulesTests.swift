import Foundation
import Testing
@testable import MacMonitor

struct UsageRulesTests {
    private func signals(
        orphan: Bool = false, lost: String? = nil, idle: TimeInterval = 0,
        growth: Double? = nil, monotonic: Bool = false, same: Int = 1
    ) -> UsageSignals {
        UsageSignals(
            groupID: "g", displayName: "g", kind: .cli, executablePath: nil, arguments: [], cwd: nil, ports: [],
            establishedConnections: 0, processCount: 1, sameNameMaxCount: same, uptimeSeconds: 0,
            idleSeconds: idle, isOrphan: orphan, lostAncestor: lost, footprint: 0,
            footprintGrowthPercent: growth, footprintMonotonic: monotonic, cpuPercent: 0
        )
    }

    private let min30: TimeInterval = 1800

    @Test func orphanIdleIsTerminate() {
        let outcome = UsageRules.evaluate(signals(orphan: true, lost: "codex", idle: 47 * 60))
        #expect(outcome == .tag(.terminate, reason: "codex 세션 종료됨 · 47분째 CPU 0%"))
    }

    @Test func orphanWithoutAncestorReason() {
        let outcome = UsageRules.evaluate(signals(orphan: true, idle: 2 * 3600 + 60))
        #expect(outcome == .tag(.terminate, reason: "부모 프로세스 없음 · 2시간째 한가함"))
    }

    @Test func terminalAncestorReason() {
        #expect(UsageRules.evaluate(signals(orphan: true, lost: "zsh", idle: min30)).reason == "터미널 종료됨 · 30분째 CPU 0%")
        #expect(UsageRules.evaluate(signals(orphan: true, lost: "claude", idle: min30)).reason == "claude 세션 종료됨 · 30분째 CPU 0%")
    }

    @Test func idleBoundaryIs30Minutes() {
        #expect(UsageRules.evaluate(signals(orphan: true, idle: min30 - 1)) == .none)
        #expect(UsageRules.evaluate(signals(orphan: true, idle: min30)).reason != nil)
    }

    @Test func orphanNotIdleIsNone() {
        #expect(UsageRules.evaluate(signals(orphan: true, idle: 10)) == .none)
    }

    @Test func growthBoundaryIs50Percent() {
        #expect(UsageRules.evaluate(signals(growth: 50, monotonic: true)) == .tag(.attention, reason: "30분 동안 메모리 +50%"))
        #expect(UsageRules.evaluate(signals(growth: 49.9, monotonic: true)) == .none)
        #expect(UsageRules.evaluate(signals(growth: 62.4, monotonic: true)).reason == "30분 동안 메모리 +62%")
    }

    @Test func growthNeedsMonotonicAndHistory() {
        #expect(UsageRules.evaluate(signals(growth: 80, monotonic: false)) == .none)
        #expect(UsageRules.evaluate(signals(growth: nil, monotonic: true)) == .none)
    }

    @Test func terminateBeatsAttention() {
        let outcome = UsageRules.evaluate(signals(orphan: true, idle: min30, growth: 90, monotonic: true))
        #expect(outcome == .tag(.terminate, reason: "부모 프로세스 없음 · 30분째 한가함"))
    }

    @Test func attentionBeatsAmbiguous() {
        let outcome = UsageRules.evaluate(signals(idle: min30, growth: 90, monotonic: true, same: 12))
        #expect(outcome == .tag(.attention, reason: "30분 동안 메모리 +90%"))
    }

    @Test func nonOrphanIdleIsAmbiguous() {
        #expect(UsageRules.evaluate(signals(idle: 45 * 60)) == .ambiguous(reason: "45분째 한가함"))
        #expect(UsageRules.evaluate(signals(idle: min30 - 1)) == .none)
    }

    @Test func sameNameBoundaryIs10() {
        #expect(UsageRules.evaluate(signals(same: 9)) == .none)
        #expect(UsageRules.evaluate(signals(same: 10)) == .ambiguous(reason: "같은 프로세스 10개"))
        #expect(UsageRules.evaluate(signals(idle: 3 * 3600, same: 14)) == .ambiguous(reason: "같은 프로세스 14개 · 3시간째 한가함"))
    }

    @Test func durationFormat() {
        #expect(UsageRules.duration(59 * 60 + 59) == "59분째")
        #expect(UsageRules.duration(3600) == "1시간째")
    }
}
