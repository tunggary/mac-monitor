import Foundation
import Testing
@testable import MacMonitor

struct ActivitySignalsTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let bundle = "/Applications/Safari.app"

    private func signals(kind: GroupKind) -> UsageSignals {
        UsageSignals(
            groupID: "g", displayName: "g", kind: kind, executablePath: nil, arguments: [], cwd: nil, ports: [],
            establishedConnections: 0, processCount: 1, sameNameMaxCount: 1, uptimeSeconds: 0, idleSeconds: 0,
            isOrphan: false, lostAncestor: nil, footprint: 0, footprintGrowthPercent: nil, footprintMonotonic: false,
            cpuPercent: 0
        )
    }

    private func enrich(_ s: UsageSignals, activations: [String: Date] = [:], visible: Set<Int32> = [], pids: [Int32] = [1, 2]) -> UsageSignals {
        s.enriched(bundlePath: bundle, pids: pids, activations: activations, monitorStart: now.addingTimeInterval(-600),
                   visiblePids: visible, now: now)
    }

    @Test func activatedAppGetsElapsed() {
        let result = enrich(signals(kind: .app), activations: [bundle: now.addingTimeInterval(-90)])
        #expect(result.lastActiveSeconds == 90)
        #expect(result.activeSinceMonitorStart)
    }

    @Test func neverActivatedFallsBackToMonitorStart() {
        let result = enrich(signals(kind: .app), activations: ["/Applications/Other.app": now])
        #expect(result.lastActiveSeconds == 600)
        #expect(!result.activeSinceMonitorStart)
    }

    @Test func nonAppGroupsStayNil() {
        for kind in [GroupKind.cli, .process] {
            let result = enrich(signals(kind: kind), activations: [bundle: now], visible: [1])
            #expect(result.lastActiveSeconds == nil)
            #expect(!result.activeSinceMonitorStart)
            #expect(result.hasVisibleWindow == nil)
        }
    }

    @Test func visibleWindowMapsAnyPid() {
        #expect(enrich(signals(kind: .app), visible: [2, 99]).hasVisibleWindow == true)
        #expect(enrich(signals(kind: .app), visible: [99]).hasVisibleWindow == false)
        #expect(enrich(signals(kind: .app), visible: []).hasVisibleWindow == false)
    }

    @Test func windowPidsKeepOnlyLayerZero() {
        let windows: [[String: Any]] = [
            ["kCGWindowOwnerPID": 10, "kCGWindowLayer": 0],
            ["kCGWindowOwnerPID": 11, "kCGWindowLayer": 25], // 메뉴바
            ["kCGWindowOwnerPID": 12, "kCGWindowLayer": 0],
            ["kCGWindowOwnerPID": 10, "kCGWindowLayer": 0],
            ["kCGWindowLayer": 0], // pid 없음
        ]
        #expect(VisibleWindowProbe.pids(from: windows) == [10, 12])
    }
}
