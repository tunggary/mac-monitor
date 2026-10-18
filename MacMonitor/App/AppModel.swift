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
    var settings = Settings.load()

    @ObservationIgnored private var cpuBuffer = RingBuffer<Double>()
    @ObservationIgnored private var memoryBuffer = RingBuffer<Double>()
    @ObservationIgnored private var swapBuffer = RingBuffer<Double>()
    @ObservationIgnored private let systemSampler = SystemSampler()
    @ObservationIgnored private let processMonitor = ProcessMonitor()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// 메뉴바 쪽이 상태 변화를 받는 훅 (뷰가 아니라 관찰 불필요)
    @ObservationIgnored var onUpdate: (() -> Void)?

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

    private func sampleSystem() {
        let snapshot = systemSampler.sample()
        cpuBuffer.append(snapshot.cpuBusy)
        memoryBuffer.append(snapshot.memoryPercent)
        swapBuffer.append(Double(snapshot.swapUsedBytes))

        let level = Judgement.memoryLevel(swapBytes: snapshot.swapUsedBytes, availablePercent: snapshot.availablePercent, settings: settings)
        if level == .danger {
            dangerSince = dangerSince ?? snapshot.date
        } else {
            dangerSince = nil
        }
        memoryLevel = level
        latest = snapshot
        tick &+= 1
        onUpdate?()
    }

    private func apply(groups: [AppGroup]) {
        self.groups = groups
        tick &+= 1
        onUpdate?()
    }
}
