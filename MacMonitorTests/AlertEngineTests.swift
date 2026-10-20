import Foundation
import Testing
@testable import MacMonitor

struct AlertEngineTests {
    private let settings = Settings() // 반복 10분, CPU 300%, 30초
    private let t0 = Date(timeIntervalSince1970: 10_000)
    private let gb: UInt64 = 1_073_741_824

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func memoryFiresOnEntryThenAtIntervals() {
        var engine = AlertEngine()
        do { let v = engine.memory(level: .danger, now: at(0), settings: settings); #expect(v) } 
        do { let v = engine.memory(level: .danger, now: at(1), settings: settings); #expect(!v) } 
        do { let v = engine.memory(level: .danger, now: at(599), settings: settings); #expect(!v) } 
        do { let v = engine.memory(level: .danger, now: at(600), settings: settings); #expect(v) } 
        do { let v = engine.memory(level: .danger, now: at(1100), settings: settings); #expect(!v) } 
        do { let v = engine.memory(level: .danger, now: at(1200), settings: settings); #expect(v) } 
    }

    @Test func memoryResetsWhenNormalOrCaution() {
        var engine = AlertEngine()
        do { let v = engine.memory(level: .danger, now: at(0), settings: settings); #expect(v) } 
        do { let v = engine.memory(level: .caution, now: at(5), settings: settings); #expect(!v) } 
        do { let v = engine.memory(level: .danger, now: at(10), settings: settings); #expect(v) } // 주의를 거쳤으니 새 진입
        do { let v = engine.memory(level: .normal, now: at(20), settings: settings); #expect(!v) } 
        do { let v = engine.memory(level: .danger, now: at(30), settings: settings); #expect(v) } 
    }

    @Test func memoryCautionNeverAlerts() {
        var engine = AlertEngine()
        for second in stride(from: 0.0, to: 3600, by: 1) {
            do { let v = engine.memory(level: .caution, now: at(second), settings: settings); #expect(!v) } 
        }
    }

    @Test func memoryNoRepeatWhenIntervalIsZero() {
        var engine = AlertEngine()
        var noRepeat = settings
        noRepeat.repeatIntervalMinutes = 0
        do { let v = engine.memory(level: .danger, now: at(0), settings: noRepeat); #expect(v) } 
        do { let v = engine.memory(level: .danger, now: at(100_000), settings: noRepeat); #expect(!v) } 
    }

    @Test func memoryRepeatIntervalFollowsSettings() {
        var engine = AlertEngine()
        var five = settings
        five.repeatIntervalMinutes = 5
        do { let v = engine.memory(level: .danger, now: at(0), settings: five); #expect(v) } 
        do { let v = engine.memory(level: .danger, now: at(300), settings: five); #expect(v) } 
    }

    @Test func cpuNeedsMoreThanSpikeSeconds() {
        var engine = AlertEngine()
        let hot = [(id: "a", percent: 340.0)]
        var fired: [(Double, AlertEngine.CPUSpike)] = []
        for second in stride(from: 0.0, through: 36, by: 3) {
            for spike in engine.cpu(groups: hot, now: at(second), settings: settings) { fired.append((second, spike)) }
        }
        #expect(fired.count == 1)
        #expect(fired[0].0 == 33) // 30초는 "넘게"가 아니므로 다음 샘플
        #expect(fired[0].1 == .init(groupID: "a", seconds: 33))
    }

    @Test func cpuDropsBelowResets() {
        var engine = AlertEngine()
        do { let v = engine.cpu(groups: [("a", 400)], now: at(0), settings: settings); #expect(v.isEmpty) } 
        do { let v = engine.cpu(groups: [("a", 400)], now: at(24), settings: settings); #expect(v.isEmpty) } 
        do { let v = engine.cpu(groups: [("a", 100)], now: at(27), settings: settings); #expect(v.isEmpty) } // 초기화
        do { let v = engine.cpu(groups: [("a", 400)], now: at(30), settings: settings); #expect(v.isEmpty) } // 새로 시작
        do { let v = engine.cpu(groups: [("a", 400)], now: at(60), settings: settings); #expect(v.isEmpty) } // 30초 경과(넘지 않음)
        do { let v = engine.cpu(groups: [("a", 400)], now: at(63), settings: settings); #expect(v.count == 1) } 
    }

    @Test func cpuGroupsAreIndependent() {
        var engine = AlertEngine()
        _ = engine.cpu(groups: [("a", 400)], now: at(0), settings: settings)
        _ = engine.cpu(groups: [("a", 400), ("b", 350)], now: at(20), settings: settings)
        let spikes = engine.cpu(groups: [("a", 400), ("b", 350)], now: at(33), settings: settings)
        #expect(spikes.map(\.groupID) == ["a"]) // b 는 13초째
        let later = engine.cpu(groups: [("a", 400), ("b", 350)], now: at(51), settings: settings)
        #expect(later.map(\.groupID) == ["b"]) // b 31초째, a 는 반복 간격 전
    }

    @Test func cpuRepeatsAtInterval() {
        var engine = AlertEngine()
        let hot = [(id: "a", percent: 400.0)]
        var count = 0
        for second in stride(from: 0.0, through: 1300, by: 3) {
            count += engine.cpu(groups: hot, now: at(second), settings: settings).count
        }
        #expect(count == 3) // 33초, 633초, 1233초
    }

    @Test func cpuVanishedGroupResets() {
        var engine = AlertEngine()
        _ = engine.cpu(groups: [("a", 400)], now: at(0), settings: settings)
        _ = engine.cpu(groups: [], now: at(15), settings: settings)
        do { let v = engine.cpu(groups: [("a", 400)], now: at(33), settings: settings); #expect(v.isEmpty) } 
    }

    // MARK: 문구

    private func group(_ name: String, gbs: Double, cpu: Double = 0, terminable: Bool = true, kind: GroupKind = .app) -> AppGroup {
        AppGroup(
            id: name, kind: kind, displayName: name, bundlePath: nil, processCount: 3,
            footprint: UInt64(gbs * Double(gb)), cpuPercent: cpu, cwdFolder: kind == .cli ? "web" : nil,
            ports: kind == .cli ? [3110] : [], pids: [10, 11], subgroups: [], terminablePids: terminable ? [10, 11] : []
        )
    }

    private let fakeIdentities: ([Int32]) -> [ProcessIdentity] = { pids in
        pids.map { ProcessIdentity(pid: $0, startSeconds: 1, startMicroseconds: 2) }
    }

    @Test func memoryMessage() {
        let groups = [group("Aside", gbs: 20.7), group("ego lite", gbs: 3.9), group("Claude", gbs: 1.8), group("Slack", gbs: 1.3)]
        let message = AlertMessages.memory(
            cause: .swap, swapBytes: UInt64(12.7 * Double(gb)), availablePercent: 40, groups: groups, identities: fakeIdentities)
        #expect(message.title == "[위험] 메모리 — 스왑 12.7 GB")
        #expect(message.body == "Aside 20.7 GB · ego lite 3.9 GB · Claude 1.8 GB")
        #expect(message.targets.map(\.name) == ["Aside", "ego lite", "Claude"])
        #expect(message.targets[0].ids.map(\.pid) == [10, 11])
        #expect(message.targets[0].groupID == "Aside")
        #expect(message.playsSound)

        let available = AlertMessages.memory(
            cause: .availableMemory, swapBytes: 0, availablePercent: 18, groups: groups, identities: fakeIdentities)
        #expect(available.title == "[위험] 메모리 — 사용 가능 18%")
    }

    @Test func memoryMessageSkipsNonTerminableActions() {
        let groups = [group("WindowServer", gbs: 5, terminable: false), group("Aside", gbs: 4)]
        let message = AlertMessages.memory(cause: .swap, swapBytes: 0, availablePercent: 40, groups: groups, identities: fakeIdentities)
        #expect(message.body.hasPrefix("WindowServer 5.0 GB"))
        #expect(message.targets.map(\.name) == ["Aside"])
    }

    @Test func cpuMessage() {
        let cli = group("next-server", gbs: 1, cpu: 340, kind: .cli)
        let message = AlertMessages.cpu(group: cli, seconds: 35, identities: fakeIdentities)
        #expect(message.title == "[주의] CPU 급증 — next-server 340%")
        #expect(message.body == "web · :3110 · 3개 · 35초째")
        #expect(message.targets.map(\.name) == ["next-server"])
        #expect(!message.playsSound)
        #expect(AlertMessages.cpu(group: group("App", gbs: 1, cpu: 400), seconds: 33, identities: fakeIdentities).body == "프로세스 3개 · 33초째")
        #expect(AlertMessages.duration(seconds: 59) == "59초")
        #expect(AlertMessages.duration(seconds: 605) == "10분")
    }

    @Test func killTargetsRoundTripThroughJSON() throws {
        let targets = [KillTarget(groupID: "/Applications/Aside.app", name: "Aside", ids: [ProcessIdentity(pid: 1, startSeconds: 2, startMicroseconds: 3)])]
        let data = try JSONEncoder().encode(targets)
        #expect(try JSONDecoder().decode([KillTarget].self, from: data) == targets)
    }
}
