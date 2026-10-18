import Foundation
import Observation

enum AppSort: Sendable, Equatable {
    case memory, cpu
}

/// 프로세스 샘플링을 메인 스레드 밖에서 돌린다. ProcessSampler 는 상태를 가지므로 이 actor 안에서만 쓴다.
actor ProcessMonitor {
    private let sampler = ProcessSampler()

    func sample() -> [AppGroup] {
        Grouping.group(sampler.sample(), selfPid: getpid(), currentUID: getuid())
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var latest: SystemSnapshot?
    private(set) var groups: [AppGroup] = []
    private(set) var memoryLevel: MemoryLevel = .normal
    private(set) var dangerSince: Date?
    /// 시계열은 링버퍼에 있어 관찰 대상이 아니다. 뷰는 이 값을 읽어 갱신을 받는다.
    private(set) var tick = 0
    var range: TimeRange = .tenMinutes
    var sort: AppSort = .memory
    /// 값이 바뀌면 UserDefaults 에 저장하고 판정에 바로 반영한다.
    var settings = Settings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if let latest { updateMemoryLevel(snapshot: latest) }
            onUpdate?()
        }
    }
    /// 펼친 행의 그룹 id (한 번에 하나)
    var expandedID: String?
    let kill = KillCoordinator()

    @ObservationIgnored private var cpuBuffer = RingBuffer<Double>()
    @ObservationIgnored private var memoryBuffer = RingBuffer<Double>()
    @ObservationIgnored private var swapBuffer = RingBuffer<Double>()
    @ObservationIgnored private let systemSampler = SystemSampler()
    @ObservationIgnored private let processMonitor = ProcessMonitor()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// 메뉴바 쪽이 상태 변화를 받는 훅 (뷰가 아니라 관찰 불필요)
    @ObservationIgnored var onUpdate: (() -> Void)?
    /// 보낼 알림이 생겼을 때
    @ObservationIgnored var onAlert: ((AlertMessage) -> Void)?
    /// 알림 버튼으로 종료했는데 3초 뒤에도 살아 있을 때 (팝오버를 열려고)
    @ObservationIgnored var onForceKillPrompt: (() -> Void)?
    @ObservationIgnored private var alertEngine = AlertEngine()

    var dangerCause: DangerCause? {
        guard let latest else { return nil }
        return Judgement.dangerCause(swapBytes: latest.swapUsedBytes, availablePercent: latest.availablePercent, settings: settings)
    }

    var isCPUCaution: Bool { Judgement.isCPUCaution(groups: groups, settings: settings) }

    var rowDots: [String: RowDot] { Judgement.rowDots(groups: groups, level: memoryLevel, settings: settings) }

    /// 메모리 footprint 가 가장 큰 그룹 (위험 배너의 "가장 큰 원인")
    var topMemoryGroup: AppGroup? { groups.max { $0.footprint < $1.footprint } }

    /// 상위 앱 5개 (정렬 기준에 따라)
    var topApps: [AppGroup] {
        let sorted: [AppGroup]
        switch sort {
        case .memory: sorted = groups.sorted { $0.footprint > $1.footprint }
        case .cpu: sorted = groups.sorted { $0.cpuPercent > $1.cpuPercent }
        }
        return Array(sorted.prefix(5))
    }

    enum Metric { case cpu, memory, swapGB }

    func chartPoints(_ metric: Metric) -> [ChartPoint] {
        let values: [Double]
        switch metric {
        case .cpu: values = cpuBuffer.recent(range)
        case .memory: values = memoryBuffer.recent(range)
        case .swapGB: values = swapBuffer.recent(range).map { $0 / Settings.bytesPerGB }
        }
        let maxPoints = range == .oneHour ? ChartSeries.hourMaxPoints : range.sampleCount
        return ChartSeries.points(values: values, rangeSamples: range.sampleCount, maxPoints: maxPoints)
    }

    func start() {
        guard tasks.isEmpty else { return }
        kill.onConfirmShown = { [weak self] groupID in
            self?.expandedID = groupID
            self?.onForceKillPrompt?()
        }
        kill.groupExists = { [weak self] groupID in self?.groups.contains { $0.id == groupID } ?? false }
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(200))
                self?.sampleSystem()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let monitor = self?.processMonitor else { return }
                let groups = await monitor.sample()
                self?.apply(groups: groups)
                try? await Task.sleep(for: .seconds(3), tolerance: .milliseconds(500))
            }
        })
    }

    /// 알림의 종료 버튼: 알림 시점의 신원에 SIGTERM, 3초 뒤 생존자가 있으면 팝오버의 강제종료 확인 박스(팝오버 내 종료와 같은 상태)
    func terminateFromAlert(_ target: KillTarget) {
        kill.terminate(key: KillCoordinator.groupKey(target.groupID), groupID: target.groupID, name: target.name, targets: target.ids)
    }

    private func sampleSystem() {
        let snapshot = systemSampler.sample()
        cpuBuffer.append(snapshot.cpuBusy)
        memoryBuffer.append(snapshot.memoryPercent)
        swapBuffer.append(Double(snapshot.swapUsedBytes))

        updateMemoryLevel(snapshot: snapshot)
        latest = snapshot
        tick &+= 1
        evaluateMemoryAlert(snapshot: snapshot)
        onUpdate?()
    }

    private func updateMemoryLevel(snapshot: SystemSnapshot) {
        let level = Judgement.memoryLevel(swapBytes: snapshot.swapUsedBytes, availablePercent: snapshot.availablePercent, settings: settings)
        dangerSince = level == .danger ? (dangerSince ?? snapshot.date) : nil
        memoryLevel = level
    }

    private func evaluateMemoryAlert(snapshot: SystemSnapshot) {
        // 원인 앱 목록이 아직 없으면(시작 직후) 다음 틱으로 미룬다
        if memoryLevel == .danger, groups.isEmpty { return }
        guard alertEngine.memory(level: memoryLevel, now: snapshot.date, settings: settings),
              let cause = dangerCause else { return }
        onAlert?(AlertMessages.memory(
            cause: cause, swapBytes: snapshot.swapUsedBytes, availablePercent: snapshot.availablePercent, groups: groups
        ))
    }

    private func apply(groups: [AppGroup]) {
        self.groups = groups
        let ids = Set(groups.map(\.id))
        if let expandedID, !ids.contains(expandedID) { self.expandedID = nil }
        kill.prune(existingGroupIDs: ids)
        for spike in alertEngine.cpu(groups: groups.map { ($0.id, $0.cpuPercent) }, now: Date(), settings: settings) {
            if let group = groups.first(where: { $0.id == spike.groupID }) {
                onAlert?(AlertMessages.cpu(group: group, seconds: spike.seconds))
            }
        }
        tick &+= 1
        onUpdate?()
    }
}
