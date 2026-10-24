import Foundation

/// 3초 샘플마다 그룹별 사용 신호(한가한 시간·메모리 추이·고아 여부)를 쌓는다.
/// 상태를 가지므로 ProcessMonitor actor 안에서만 쓴다. 시간은 `now` 로 주입한다.
final class UsageTracker {
    static let historyWindow: TimeInterval = 30 * 60
    static let historyInterval: TimeInterval = 60
    static let idleCPUPercent = 1.0
    static let ancestorDepth = 8
    static let monotonicTolerance = 0.05

    private struct ProcessID: Hashable {
        var pid: Int32
        var start: TimeInterval
    }

    private struct ProcessState {
        /// 지금까지 본 가장 가까운 조상 이름 (claude·codex·터미널·셸)
        var ancestor: String?
        var firstSeenUnderLaunchd: Bool
    }

    private struct History {
        var entries: [(date: Date, footprint: UInt64)] = []
    }

    private var processes: [ProcessID: ProcessState] = [:]
    private var idleSince: [String: Date] = [:]
    private var histories: [String: History] = [:]

    func update(samples: [ProcessSample], groups: [AppGroup], now: Date) -> [String: UsageSignals] {
        let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var orphans: [Int32: String?] = [:] // pid → lostAncestor (키가 있으면 고아)
        var nextProcesses: [ProcessID: ProcessState] = [:]

        for sample in samples {
            let id = processID(sample)
            var state = processes[id] ?? ProcessState(ancestor: nil, firstSeenUnderLaunchd: sample.ppid <= 1)
            if sample.ppid > 1, let found = closestAncestor(of: sample, byPid: byPid) { state.ancestor = found }
            nextProcesses[id] = state
            if sample.ppid <= 1 {
                if let ancestor = state.ancestor {
                    orphans[sample.pid] = ancestor
                } else if state.firstSeenUnderLaunchd, Grouping.outermostBundle(path: sample.path) == nil {
                    orphans[sample.pid] = .some(nil)
                }
            }
        }
        processes = nextProcesses

        var result: [String: UsageSignals] = [:]
        for group in groups {
            let members = group.pids.compactMap { byPid[$0] }
            guard !members.isEmpty else { continue }
            result[group.id] = signals(group: group, members: members, orphans: orphans, now: now)
        }

        let ids = Set(result.keys)
        idleSince = idleSince.filter { ids.contains($0.key) }
        histories = histories.filter { ids.contains($0.key) }
        return result
    }

    private func signals(group: AppGroup, members: [ProcessSample], orphans: [Int32: String?], now: Date) -> UsageSignals {
        let established = members.reduce(0) { $0 + $1.establishedConnections }

        var idle: TimeInterval = 0
        if group.cpuPercent < Self.idleCPUPercent, established == 0 {
            let since = idleSince[group.id] ?? now
            idleSince[group.id] = since
            idle = max(0, now.timeIntervalSince(since))
        } else {
            idleSince[group.id] = nil
        }

        let growth = trackFootprint(groupID: group.id, footprint: group.footprint, now: now)

        let isOrphan = group.kind != .app && members.allSatisfy { orphans[$0.pid] != nil }
        let lost = isOrphan ? members.sorted { $0.pid < $1.pid }.lazy.compactMap { orphans[$0.pid] ?? nil }.first : nil

        let representative = members.max { ($0.footprint ?? 0, $1.pid) < ($1.footprint ?? 0, $0.pid) } ?? members[0]
        let oldest = members.compactMap(\.startDate).min()
        let sameName = Dictionary(grouping: members, by: \.name).values.map(\.count).max() ?? 0

        return UsageSignals(
            groupID: group.id, displayName: group.displayName, kind: group.kind,
            executablePath: representative.path, arguments: representative.arguments, cwd: representative.cwd,
            ports: group.ports, establishedConnections: established, processCount: group.processCount,
            sameNameMaxCount: sameName, uptimeSeconds: oldest.map { max(0, now.timeIntervalSince($0)) } ?? 0,
            idleSeconds: idle, isOrphan: isOrphan, lostAncestor: lost,
            footprint: group.footprint, footprintGrowthPercent: growth.percent, footprintMonotonic: growth.monotonic,
            cpuPercent: group.cpuPercent
        )
    }

    /// 1분 간격 이력에 쌓고 30분 전 대비 증가율을 돌려준다. 이력이 30분이 안 되면 percent 는 nil.
    private func trackFootprint(groupID: String, footprint: UInt64, now: Date) -> (percent: Double?, monotonic: Bool) {
        var history = histories[groupID] ?? History()
        if history.entries.last.map({ now.timeIntervalSince($0.date) >= Self.historyInterval }) ?? true {
            history.entries.append((now, footprint))
        }
        // 기준 시점(30분 전 이하 중 가장 최근) 하나만 남기고 그 앞은 버린다
        let cutoff = now.addingTimeInterval(-Self.historyWindow)
        while history.entries.count >= 2, history.entries[1].date <= cutoff { history.entries.removeFirst() }
        histories[groupID] = history

        guard let base = history.entries.first, base.date <= cutoff, base.footprint > 0 else { return (nil, false) }
        let percent = (Double(footprint) - Double(base.footprint)) / Double(base.footprint) * 100
        // 직전 값보다 5% 이내로 줄어든 건 출렁임으로 보고 감소로 치지 않는다
        let monotonic = zip(history.entries, history.entries.dropFirst()).allSatisfy {
            Double($1.footprint) >= Double($0.footprint) * (1 - Self.monotonicTolerance)
        }
        return (percent, monotonic)
    }

    // MARK: 조상

    private func processID(_ sample: ProcessSample) -> ProcessID {
        ProcessID(pid: sample.pid, start: sample.startDate?.timeIntervalSince1970 ?? 0)
    }

    /// ppid 를 따라 올라가며(최대 8단계) 만나는 조상 이름. 에이전트(claude·codex)가 있으면 그쪽을 우선한다 —
    /// 에이전트는 셸(zsh -c)을 거쳐 명령을 띄우므로 가장 가까운 조상은 대개 셸이다. 없으면 가장 가까운 터미널·셸.
    private func closestAncestor(of sample: ProcessSample, byPid: [Int32: ProcessSample]) -> String? {
        var current = sample
        var nearest: String?
        for _ in 0..<Self.ancestorDepth {
            guard current.ppid > 1, let parent = byPid[current.ppid] else { break }
            if Self.isTrackedAncestor(parent) {
                let name = Grouping.displayName(name: parent.name, path: parent.path)
                if Self.agentNames.contains(name.lowercased()) { return name }
                nearest = nearest ?? name
            }
            current = parent
        }
        return nearest
    }

    static let agentNames: Set<String> = ["claude", "codex"]

    static func isTrackedAncestor(_ sample: ProcessSample) -> Bool {
        // Claude Code 는 프로세스 이름이 버전 문자열("2.1.302")이라 경로로 보정한 이름을 본다
        let name = Grouping.displayName(name: sample.name, path: sample.path).lowercased()
        if agentNames.contains(name) || Grouping.isShell(sample.name) { return true }
        if let bundle = Grouping.outermostBundle(path: sample.path) { return Grouping.isTerminal(bundlePath: bundle) }
        return Grouping.terminalNames.contains(name)
    }
}
