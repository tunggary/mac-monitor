import Foundation

/// "처음 1회, 계속되면 간격마다" 규칙
struct RepeatGate: Sendable, Equatable {
    private(set) var lastFired: Date?

    /// 지금 알려야 하면 true (시각을 기록한다). `repeatMinutes` 0 = 처음 1회뿐.
    mutating func fire(now: Date, repeatMinutes: Int) -> Bool {
        guard let lastFired else {
            self.lastFired = now
            return true
        }
        guard repeatMinutes > 0, now.timeIntervalSince(lastFired) >= Double(repeatMinutes) * 60 else { return false }
        self.lastFired = now
        return true
    }
}

/// 알림을 보낼지 판정하는 순수 상태 기계. 시각은 호출하는 쪽이 넘긴다.
/// 메모리 상태(1초마다)와 그룹별 CPU(3초마다)를 따로 받는다.
struct AlertEngine: Sendable, Equatable {
    struct CPUSpike: Sendable, Equatable {
        var groupID: String
        /// 기준 이상이 이어진 시간(초)
        var seconds: Int
    }

    private var memoryGate = RepeatGate()
    private struct CPUState: Equatable {
        var since: Date
        var gate = RepeatGate()
    }
    private var cpuStates: [String: CPUState] = [:]

    /// 메모리 위험이 알림을 낼 때인가. 정상·주의로 내려가면 초기화한다.
    mutating func memory(level: MemoryLevel, now: Date, settings: Settings) -> Bool {
        guard level == .danger else {
            memoryGate = RepeatGate()
            return false
        }
        return memoryGate.fire(now: now, repeatMinutes: settings.repeatIntervalMinutes)
    }

    /// CPU ≥ 기준이 지속시간을 넘게(>) 이어진 그룹. 그룹별 독립이고, 기준 아래로 내려가거나 사라진 그룹은 초기화한다.
    mutating func cpu(groups: [(id: String, percent: Double)], now: Date, settings: Settings) -> [CPUSpike] {
        let over = Set(groups.filter { $0.percent >= settings.appCPUCautionPercent }.map(\.id))
        cpuStates = cpuStates.filter { over.contains($0.key) }

        var spikes: [CPUSpike] = []
        for id in groups.map(\.id) where over.contains(id) {
            var state = cpuStates[id] ?? CPUState(since: now)
            let elapsed = now.timeIntervalSince(state.since)
            if elapsed > settings.spikeSeconds, state.gate.fire(now: now, repeatMinutes: settings.repeatIntervalMinutes) {
                spikes.append(CPUSpike(groupID: id, seconds: Int(elapsed)))
            }
            cpuStates[id] = state
        }
        return spikes
    }
}
