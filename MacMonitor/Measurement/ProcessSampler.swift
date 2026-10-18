import Darwin
import Foundation

struct ProcessSample: Sendable, Equatable {
    var pid: Int32
    var ppid: Int32
    var uid: UInt32
    var name: String
    /// 실행 파일 경로
    var path: String?
    var cwd: String?
    /// ri_phys_footprint. rusage 를 못 읽은 프로세스(다른 uid 등)는 nil.
    var footprint: UInt64?
    /// 코어 1개 = 100%
    var cpuPercent: Double
    var listenPorts: [UInt16]
    var responsiblePid: Int32?

    init(
        pid: Int32, ppid: Int32 = 1, uid: UInt32 = 501, name: String, path: String? = nil,
        cwd: String? = nil, footprint: UInt64? = nil, cpuPercent: Double = 0,
        listenPorts: [UInt16] = [], responsiblePid: Int32? = nil
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
        self.cwd = cwd
        self.footprint = footprint
        self.cpuPercent = cpuPercent
        self.listenPorts = listenPorts
        self.responsiblePid = responsiblePid
    }
}

enum ProcessMath {
    /// mach absolute time → 나노초. Apple Silicon 은 timebase 125/3.
    static func nanoseconds(machTicks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard denom > 0 else { return machTicks }
        let (high, low) = machTicks.multipliedFullWidth(by: UInt64(numer))
        return UInt64(denom).dividingFullWidth((high, low)).quotient
    }

    /// CPU 시간 델타 / 벽시계 델타 × 100 (코어 1개 = 100%)
    static func cpuPercent(previousCPUNanoseconds: UInt64, currentCPUNanoseconds: UInt64, wallNanoseconds: UInt64) -> Double {
        guard wallNanoseconds > 0, currentCPUNanoseconds >= previousCPUNanoseconds else { return 0 }
        return Double(currentCPUNanoseconds - previousCPUNanoseconds) / Double(wallNanoseconds) * 100
    }
}

/// 3초 간격으로 불러 쓰는 프로세스 샘플러. 상태(이전 CPU 시간, 캐시)를 가지므로 한 곳에서만 호출한다.
final class ProcessSampler {
    private struct Key: Hashable {
        var pid: Int32
        var startSeconds: UInt64
        var startMicroseconds: UInt64
    }

    /// 프로세스 수명 동안 잘 안 바뀌는 값 (pid + 시작시간 키로 캐시)
    private struct StaticInfo {
        var path: String?
        var cwd: String?
        var responsiblePid: Int32?
    }

    private struct PortEntry {
        var ports: [UInt16]
        var fetchedAt: TimeInterval
    }

    static let portTTL: TimeInterval = 30

    private var staticCache: [Key: StaticInfo] = [:]
    private var portCache: [Key: PortEntry] = [:]
    private var previousCPU: [Key: UInt64] = [:]
    private var previousDate: Date?
    private let timebase: (numer: UInt32, denom: UInt32)
    private let currentUID = getuid()

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (info.numer, info.denom)
    }

    func sample(now: Date = Date()) -> [ProcessSample] {
        let wallNanoseconds = previousDate.map { UInt64(max(0, now.timeIntervalSince($0)) * 1_000_000_000) } ?? 0
        var seen = Set<Key>()
        var nextCPU: [Key: UInt64] = [:]
        var results: [ProcessSample] = []

        for pid in Self.allPids() {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }

            let key = Key(pid: pid, startSeconds: bsd.pbi_start_tvsec, startMicroseconds: bsd.pbi_start_tvusec)
            seen.insert(key)

            var name = cString(bsd.pbi_name)
            if name.isEmpty { name = cString(bsd.pbi_comm) }

            let info: StaticInfo
            if let cached = staticCache[key] {
                info = cached
            } else {
                info = StaticInfo(
                    path: Self.executablePath(pid),
                    cwd: Self.currentDirectory(pid),
                    responsiblePid: Responsibility.responsiblePid(for: pid)
                )
                staticCache[key] = info
            }
            if name.isEmpty, let path = info.path { name = (path as NSString).lastPathComponent }

            var footprint: UInt64?
            var cpuPercent = 0.0
            if let usage = Self.rusage(pid) {
                footprint = usage.ri_phys_footprint
                let cpuNs = ProcessMath.nanoseconds(
                    machTicks: usage.ri_user_time &+ usage.ri_system_time,
                    numer: timebase.numer, denom: timebase.denom
                )
                nextCPU[key] = cpuNs
                if let previous = previousCPU[key] {
                    cpuPercent = ProcessMath.cpuPercent(
                        previousCPUNanoseconds: previous, currentCPUNanoseconds: cpuNs, wallNanoseconds: wallNanoseconds
                    )
                }
            }

            results.append(ProcessSample(
                pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid, name: name,
                path: info.path, cwd: info.cwd, footprint: footprint, cpuPercent: cpuPercent,
                listenPorts: listenPorts(key: key, uid: bsd.pbi_uid, now: now.timeIntervalSince1970),
                responsiblePid: info.responsiblePid
            ))
        }

        staticCache = staticCache.filter { seen.contains($0.key) }
        portCache = portCache.filter { seen.contains($0.key) }
        previousCPU = nextCPU
        previousDate = now
        return results
    }

    // MARK: 리슨 포트 (30초 TTL, pid 별로 만료 시점을 어긋나게 해 한 번에 몰리지 않게 한다)

    private func listenPorts(key: Key, uid: UInt32, now: TimeInterval) -> [UInt16] {
        guard uid == currentUID else { return [] } // 다른 uid 의 fd 는 읽을 수 없다
        let ttl = Self.portTTL + Double(key.pid % 10)
        if let entry = portCache[key], now - entry.fetchedAt < ttl { return entry.ports }
        let ports = Self.readListenPorts(key.pid)
        portCache[key] = PortEntry(ports: ports, fetchedAt: now)
        return ports
    }

    // MARK: libproc 래퍼

    private static func allPids() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) * 2 + 64)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.size)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private static func rusage(_ pid: Int32) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? info : nil
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    private static func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    private static func readListenPorts(_ pid: Int32) -> [UInt16] {
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return [] }
        let entrySize = MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(listSize) / entrySize + 8)
        let bytes = Int32(fds.count * entrySize)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bytes) }
        guard got > 0 else { return [] }

        var ports = Set<UInt16>()
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(got) / entrySize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize,
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP),
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN)
            else { continue }
            let networkOrder = UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            ports.insert(UInt16(bigEndian: networkOrder))
        }
        return ports.sorted()
    }
}

/// 고정 크기 C 문자 배열(튜플) → String
private func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

/// 비공개 심볼 responsibility_get_pid_responsible_for_pid (dlsym). 없거나 실패하면 nil.
enum Responsibility {
    private typealias Function = @convention(c) (pid_t) -> pid_t

    private static let function: Function? = {
        // RTLD_DEFAULT = (void *)-2
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func responsiblePid(for pid: Int32) -> Int32? {
        guard let function else { return nil }
        let result = function(pid)
        return result > 0 && result != pid ? result : nil
    }
}
