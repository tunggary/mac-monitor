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
    var startDate: Date?
    /// 실행 인자(argv). 못 읽으면 [].
    var arguments: [String]
    /// 같은 프로세스의 리슨 포트에 붙은 ESTABLISHED 연결 수
    var establishedConnections: Int

    init(
        pid: Int32, ppid: Int32 = 1, uid: UInt32 = 501, name: String, path: String? = nil,
        cwd: String? = nil, footprint: UInt64? = nil, cpuPercent: Double = 0,
        listenPorts: [UInt16] = [], responsiblePid: Int32? = nil,
        startDate: Date? = nil, arguments: [String] = [], establishedConnections: Int = 0
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
        self.startDate = startDate
        self.arguments = arguments
        self.establishedConnections = establishedConnections
    }
}

enum ProcessArgs {
    /// KERN_PROCARGS2 버퍼 → argv. 형식: Int32 argc, 실행 경로 NUL, 패딩 NUL, argv[0..<argc] (각각 NUL 종료), 그 뒤는 환경변수.
    static func parse(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let argc = bytes.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } // little-endian
        guard argc > 0 else { return [] }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 } // 실행 경로
        while index < bytes.count, bytes[index] == 0 { index += 1 } // 패딩
        var result: [String] = []
        while result.count < argc, index < bytes.count {
            var end = index
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            result.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        return result
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
        var arguments: [String]
    }

    private struct PortEntry {
        var ports: [UInt16]
        var established: Int
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
                    responsiblePid: Responsibility.responsiblePid(for: pid),
                    arguments: Self.arguments(pid)
                )
                staticCache[key] = info
            }
            if name.isEmpty, let path = info.path { name = (path as NSString).lastPathComponent }
            name = Grouping.displayName(name: name, path: info.path)

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

            let network = networkInfo(key: key, uid: bsd.pbi_uid, now: now.timeIntervalSince1970)
            results.append(ProcessSample(
                pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid, name: name,
                path: info.path, cwd: info.cwd, footprint: footprint, cpuPercent: cpuPercent,
                listenPorts: network.ports, responsiblePid: info.responsiblePid,
                startDate: Date(timeIntervalSince1970: Double(key.startSeconds) + Double(key.startMicroseconds) / 1_000_000),
                arguments: info.arguments, establishedConnections: network.established
            ))
        }

        staticCache = staticCache.filter { seen.contains($0.key) }
        portCache = portCache.filter { seen.contains($0.key) }
        previousCPU = nextCPU
        previousDate = now
        return results
    }

    // MARK: 리슨 포트 + ESTABLISHED 연결 수 (30초 TTL, pid 별로 만료 시점을 어긋나게 해 한 번에 몰리지 않게 한다)

    private func networkInfo(key: Key, uid: UInt32, now: TimeInterval) -> (ports: [UInt16], established: Int) {
        guard uid == currentUID else { return ([], 0) } // 다른 uid 의 fd 는 읽을 수 없다
        let ttl = Self.portTTL + Double(key.pid % 10)
        if let entry = portCache[key], now - entry.fetchedAt < ttl { return (entry.ports, entry.established) }
        let result = Self.readSockets(key.pid)
        portCache[key] = PortEntry(ports: result.ports, established: result.established, fetchedAt: now)
        return result
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

    /// KERN_PROCARGS2 로 argv 를 읽는다. 다른 uid 등 실패하면 [].
    private static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return ProcessArgs.parse(Array(buffer.prefix(size)))
    }

    /// 리슨 포트와, 그 포트로 들어온 ESTABLISHED 연결 수
    private static func readSockets(_ pid: Int32) -> (ports: [UInt16], established: Int) {
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return ([], 0) }
        let entrySize = MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(listSize) / entrySize + 8)
        let bytes = Int32(fds.count * entrySize)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bytes) }
        guard got > 0 else { return ([], 0) }

        var ports = Set<UInt16>()
        var establishedLocalPorts: [UInt16] = []
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(got) / entrySize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize,
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP)
            else { continue }
            let state = socket.psi.soi_proto.pri_tcp.tcpsi_state
            guard state == Int32(TSI_S_LISTEN) || state == Int32(TSI_S_ESTABLISHED) else { continue }
            let networkOrder = UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            let port = UInt16(bigEndian: networkOrder)
            if state == Int32(TSI_S_LISTEN) { ports.insert(port) } else { establishedLocalPorts.append(port) }
        }
        return (ports.sorted(), establishedLocalPorts.filter(ports.contains).count)
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
