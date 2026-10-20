import Darwin
import Observation
import Foundation

/// 같은 프로세스인지 확인하기 위한 pid + 시작시간. pid 는 재사용되므로 신호 직전에 시작시간을 다시 대조한다.
struct ProcessIdentity: Sendable, Hashable, Codable {
    var pid: Int32
    var startSeconds: UInt64
    var startMicroseconds: UInt64

    /// 지금 이 pid 의 프로세스. 없으면 nil. 좀비(종료됐지만 부모가 수거 전)도 nil.
    static func current(_ pid: Int32) -> ProcessIdentity? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        guard bsd.pbi_status != UInt32(SZOMB) else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: bsd.pbi_start_tvsec, startMicroseconds: bsd.pbi_start_tvusec)
    }

    /// kill(pid, 0) 이 성공하고(EPERM 은 살아 있지만 우리 것이 아님) 시작시간이 같을 때만 true
    var isAlive: Bool {
        guard kill(pid, 0) == 0 else { return false }
        return Self.current(pid) == self
    }
}

enum ProcessKiller {
    /// 지금 시점의 신원을 붙인다. 이미 없는 pid 는 건너뛴다.
    static func identities(of pids: [Int32]) -> [ProcessIdentity] {
        pids.compactMap(ProcessIdentity.current)
    }

    /// 신원이 아직 같은 프로세스에만 신호를 보낸다. 보낸 개수를 돌려준다.
    @discardableResult
    static func send(_ signal: Int32, to targets: [ProcessIdentity]) -> Int {
        var sent = 0
        for target in targets where ProcessIdentity.current(target.pid) == target {
            if kill(target.pid, signal) == 0 { sent += 1 }
        }
        return sent
    }

    static func terminate(_ targets: [ProcessIdentity]) { send(SIGTERM, to: targets) }
    static func forceKill(_ targets: [ProcessIdentity]) { send(SIGKILL, to: targets) }

    static func alive(_ targets: [ProcessIdentity]) -> [ProcessIdentity] {
        targets.filter(\.isAlive)
    }
}

/// 종료 요청 상태. 키 하나 = 상위 앱 줄 또는 하위 줄 하나.
/// SIGTERM 을 보낸 뒤 `grace` 가 지나도 살아 있으면 강제종료 확인 상태가 된다.
@MainActor
@Observable
final class KillCoordinator {
    struct Entry: Equatable {
        var groupID: String
        var name: String
        var targets: [ProcessIdentity]
        /// 비어 있지 않으면 강제종료 확인 박스를 보인다.
        var survivors: [ProcessIdentity] = []
        var needsConfirm: Bool { !survivors.isEmpty }
    }

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let grace: Duration
    /// 확인 박스가 뜰 때 (그 행을 펼치려고)
    @ObservationIgnored var onConfirmShown: ((_ groupID: String) -> Void)?
    /// 그 그룹이 지금 목록에 있는가. 유예 뒤 그룹이 사라졌으면 확인 박스 없이 끝낸다.
    @ObservationIgnored var groupExists: (_ groupID: String) -> Bool = { _ in true }

    init(grace: Duration = .seconds(3)) { self.grace = grace }

    static func groupKey(_ groupID: String) -> String { "G|\(groupID)" }
    static func subKey(_ groupID: String, _ subID: String) -> String { "S|\(groupID)|\(subID)" }

    /// 즉시 SIGTERM 을 보내고, 유예 뒤 생존 여부를 확인한다.
    func terminate(key: String, groupID: String, name: String, pids: [Int32]) {
        terminate(key: key, groupID: groupID, name: name, targets: ProcessKiller.identities(of: pids))
    }

    /// 이미 신원을 붙인 대상(알림 시점의 pid + 시작시간)에게 SIGTERM. pid 가 재사용됐으면 신호가 가지 않는다.
    func terminate(key: String, groupID: String, name: String, targets: [ProcessIdentity]) {
        ProcessKiller.terminate(targets)
        entries[key] = Entry(groupID: groupID, name: name, targets: targets)
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self, grace] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.checkSurvivors(key: key)
        }
    }

    private func checkSurvivors(key: String) {
        guard var entry = entries[key] else { return }
        entry.survivors = ProcessKiller.alive(entry.targets)
        tasks[key] = nil
        if entry.survivors.isEmpty || !groupExists(entry.groupID) {
            entries[key] = nil
        } else {
            entries[key] = entry
            onConfirmShown?(entry.groupID)
        }
    }

    func cancel(key: String) {
        tasks[key]?.cancel()
        tasks[key] = nil
        entries[key] = nil
    }

    /// 확인 박스의 "강제종료": 지금도 살아 있는 대상에만 SIGKILL
    func forceKill(key: String) {
        guard let entry = entries[key] else { return }
        ProcessKiller.forceKill(entry.survivors)
        cancel(key: key)
    }

    /// 목록에서 사라진 그룹의 요청은 버린다.
    func prune(existingGroupIDs: Set<String>) {
        for (key, entry) in entries where !existingGroupIDs.contains(entry.groupID) { cancel(key: key) }
    }
}
