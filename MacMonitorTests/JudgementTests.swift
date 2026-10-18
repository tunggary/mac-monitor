import Foundation
import Testing
@testable import MacMonitor

struct JudgementTests {
    private let settings = Settings()
    private let gb: UInt64 = 1_073_741_824

    private func level(swapGB: Double, available: Double) -> MemoryLevel {
        Judgement.memoryLevel(swapBytes: UInt64(swapGB * Double(gb)), availablePercent: available, settings: settings)
    }

    @Test func defaultSettings() {
        #expect(settings.swapCautionGB == 4)
        #expect(settings.swapDangerGB == 8)
        #expect(settings.availableDangerPercent == 20)
        #expect(settings.appCPUCautionPercent == 300)
        #expect(settings.spikeSeconds == 30)
        #expect(settings.repeatIntervalMinutes == 10)
    }

    @Test func memoryLevelBoundaries() {
        #expect(level(swapGB: 1.2, available: 31) == .normal)
        #expect(level(swapGB: 4, available: 31) == .normal) // 초과해야 주의
        #expect(level(swapGB: 4.1, available: 31) == .caution)
        #expect(level(swapGB: 8, available: 31) == .caution)
        #expect(level(swapGB: 8.1, available: 31) == .danger)
        #expect(level(swapGB: 0, available: 20) == .normal) // 미만이어야 위험
        #expect(level(swapGB: 0, available: 19) == .danger)
        #expect(level(swapGB: 5, available: 15) == .danger)
    }

    @Test func dangerCause() {
        func cause(_ swapGB: Double, _ available: Double) -> DangerCause? {
            Judgement.dangerCause(swapBytes: UInt64(swapGB * Double(gb)), availablePercent: available, settings: settings)
        }
        #expect(cause(12.7, 40) == .swap)
        #expect(cause(1, 18) == .availableMemory)
        #expect(cause(12, 10) == .swap)
        #expect(cause(5, 40) == nil)
    }

    @Test func settingsRoundTripThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "mac-monitor-tests-\(UUID().uuidString)"))
        #expect(Settings.load(from: defaults) == Settings())
        var changed = Settings()
        changed.swapDangerGB = 10
        changed.repeatIntervalMinutes = 0
        changed.save(to: defaults)
        #expect(Settings.load(from: defaults) == changed)
    }

    private func group(_ id: String, footprintGB: UInt64, cpu: Double = 0) -> AppGroup {
        AppGroup(
            id: id, kind: .app, displayName: id, bundlePath: nil, processCount: 1,
            footprint: footprintGB * gb, cpuPercent: cpu, cwdFolder: nil, ports: [], pids: [1],
            subgroups: [], isTerminable: true
        )
    }

    @Test func cpuChip() {
        #expect(!Judgement.isCPUCaution(groups: [group("a", footprintGB: 1, cpu: 299)], settings: settings))
        #expect(Judgement.isCPUCaution(groups: [group("a", footprintGB: 1, cpu: 300)], settings: settings))
        #expect(!Judgement.isCPUCaution(groups: [], settings: settings))
    }

    @Test func rowDotsDangerFollowSpec() {
        let groups = [
            group("d", footprintGB: 1, cpu: 350), group("a", footprintGB: 20),
            group("b", footprintGB: 4), group("c", footprintGB: 2), group("e", footprintGB: 0, cpu: 10),
        ]
        let dots = Judgement.rowDots(groups: groups, level: .danger, settings: settings)
        #expect(dots["a"] == .danger) // 1위
        #expect(dots["b"] == .warn) // 2위
        #expect(dots["c"] == .warn) // 3위
        #expect(dots["d"] == .warn) // 4위지만 CPU ≥ 300
        #expect(dots["e"] == .ok)
    }

    @Test func rowDotsCautionHasNoCoral() {
        let groups = [group("a", footprintGB: 5), group("b", footprintGB: 4), group("c", footprintGB: 3), group("d", footprintGB: 2)]
        let dots = Judgement.rowDots(groups: groups, level: .caution, settings: settings)
        #expect(!dots.values.contains(.danger))
        #expect(dots["b"] == .warn)
        #expect(dots["c"] == .warn)
        #expect(dots["d"] == .ok)
    }

    @Test func rowDotsNormalAreAllGreen() {
        let groups = [group("a", footprintGB: 5, cpu: 400), group("b", footprintGB: 4)]
        let dots = Judgement.rowDots(groups: groups, level: .normal, settings: settings)
        #expect(dots.values.allSatisfy { $0 == .ok })
    }

    @Test func dangerMinutes() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(Judgement.dangerMinutes(since: start, now: start.addingTimeInterval(5)) == 1)
        #expect(Judgement.dangerMinutes(since: start, now: start.addingTimeInterval(4 * 60 + 20)) == 4)
    }

    @Test func swapYMax() {
        #expect(Judgement.swapYMaxGB(dangerGB: 8, observedMaxGB: 12.7) == 16)
        // 위험선 8 은 절반, 주의선 4 는 1/4
        #expect(8 / Judgement.swapYMaxGB(dangerGB: 8, observedMaxGB: 0) == 0.5)
        #expect(4 / Judgement.swapYMaxGB(dangerGB: 8, observedMaxGB: 0) == 0.25)
        // 기준 2배를 넘으면 잘리지 않게 확장
        #expect(Judgement.swapYMaxGB(dangerGB: 8, observedMaxGB: 20) == 22)
    }

    @Test func formatting() {
        #expect(Format.gb(UInt64(12.7 * Double(gb))) == "12.7 GB")
        #expect(Format.memory(980 * 1_048_576) == "980 MB")
        #expect(Format.memory(UInt64(20.7 * Double(gb))) == "20.7 GB")
        #expect(Format.thresholdGB(8) == "8 GB")
    }
}

struct CharacterSpeedTests {
    private let range = PartyParrot.speedRange

    @Test func rangeMatchesSpec() {
        #expect(abs(range.lowerBound - 8.3333) < 0.001)
        #expect(abs(range.upperBound - 28.5714) < 0.001)
    }

    @Test func clampsAtEnds() {
        #expect(CharacterSpeed.framesPerSecond(cpuPercent: 0, range: range) == range.lowerBound)
        #expect(CharacterSpeed.framesPerSecond(cpuPercent: 10, range: range) == range.lowerBound)
        #expect(CharacterSpeed.framesPerSecond(cpuPercent: 90, range: range) == range.upperBound)
        #expect(CharacterSpeed.framesPerSecond(cpuPercent: 100, range: range) == range.upperBound)
    }

    @Test func interpolatesLinearlyInFps() {
        let mid = CharacterSpeed.framesPerSecond(cpuPercent: 50, range: range)
        #expect(abs(mid - (range.lowerBound + range.upperBound) / 2) < 1e-9)
        let quarter = CharacterSpeed.framesPerSecond(cpuPercent: 30, range: range)
        #expect(abs(quarter - (range.lowerBound + (range.upperBound - range.lowerBound) * 0.25)) < 1e-9)
    }
}

struct ChartSeriesTests {
    @Test func sparseDataStaysRightAligned() {
        let points = ChartSeries.points(values: [1, 2, 3], rangeSamples: 600, maxPoints: 600)
        #expect(points.map(\.x) == [-2, -1, 0])
        #expect(points.map(\.y) == [1, 2, 3])
    }

    @Test func emptyValuesGiveNoPoints() {
        #expect(ChartSeries.points(values: [], rangeSamples: 60, maxPoints: 60).isEmpty)
    }

    @Test func hourIsDownsampledToLimit() {
        let values = (0..<3600).map(Double.init)
        let points = ChartSeries.points(values: values, rangeSamples: 3600, maxPoints: ChartSeries.hourMaxPoints)
        #expect(points.count == 174)
        #expect(points.first?.x == -3599)
        #expect(points.last?.x == 0)
    }

    @Test func onlyRecentRangeIsUsed() {
        let points = ChartSeries.points(values: (0..<100).map(Double.init), rangeSamples: 60, maxPoints: 60)
        #expect(points.count == 60)
        #expect(points.first?.y == 40)
    }
}
