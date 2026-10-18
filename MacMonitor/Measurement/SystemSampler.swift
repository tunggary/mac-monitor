import Darwin
import Foundation

struct SystemSnapshot: Sendable, Equatable {
    var date: Date
    /// CPU 비율(0~100). top 의 sys / user / idle 과 같은 정의 (nice 는 user 에 합산).
    var cpuSystem: Double
    var cpuUser: Double
    var cpuIdle: Double
    /// 앱 메모리 + 와이어드 + 압축됨 (바이트)
    var appMemoryBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var totalMemoryBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    /// kern.memorystatus_level (0~100)
    var availablePercent: Double

    /// 큰 수치 = 100 − 대기
    var cpuBusy: Double { 100 - cpuIdle }
    var memoryPercent: Double {
        MemoryMath.memoryPercent(
            appBytes: appMemoryBytes, wiredBytes: wiredBytes,
            compressedBytes: compressedBytes, totalBytes: totalMemoryBytes
        )
    }
    var pressurePercent: Double { 100 - availablePercent }
}

/// host_statistics64(HOST_CPU_LOAD_INFO) 의 누적 틱.
struct CPUTicks: Sendable, Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64
}

/// host_statistics64(HOST_VM_INFO64) 에서 쓰는 카운트(페이지 단위).
struct VMCounts: Sendable, Equatable {
    var pageSize: UInt64
    var internalPages: UInt64
    var purgeablePages: UInt64
    var wirePages: UInt64
    var compressorPages: UInt64
}

enum CPUMath {
    /// 두 시점의 틱 델타 → (system, user, idle) %. nice 는 user 에 합산. 델타가 0 이면 idle 100.
    /// 틱 카운터는 32비트로 감기므로 UInt32 래핑 뺄셈을 쓴다.
    static func percentages(previous: CPUTicks, current: CPUTicks) -> (system: Double, user: Double, idle: Double) {
        func delta(_ new: UInt64, _ old: UInt64) -> Double {
            Double(UInt32(truncatingIfNeeded: new) &- UInt32(truncatingIfNeeded: old))
        }
        let user = delta(current.user, previous.user) + delta(current.nice, previous.nice)
        let system = delta(current.system, previous.system)
        let idle = delta(current.idle, previous.idle)
        let total = user + system + idle
        guard total > 0 else { return (0, 0, 100) }
        return (system / total * 100, user / total * 100, idle / total * 100)
    }
}

enum MemoryMath {
    /// 앱 메모리 = (internal − purgeable) × pagesize
    static func appMemoryBytes(_ vm: VMCounts) -> UInt64 {
        (vm.internalPages &- min(vm.purgeablePages, vm.internalPages)) &* vm.pageSize
    }

    static func wiredBytes(_ vm: VMCounts) -> UInt64 { vm.wirePages &* vm.pageSize }
    static func compressedBytes(_ vm: VMCounts) -> UInt64 { vm.compressorPages &* vm.pageSize }

    static func memoryPercent(appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, totalBytes: UInt64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return Double(appBytes + wiredBytes + compressedBytes) / Double(totalBytes) * 100
    }
}

/// 1초 간격으로 불러 쓰는 시스템 지표 샘플러. CPU 는 이전 호출과의 틱 델타로 계산한다.
final class SystemSampler {
    private var previousTicks: CPUTicks?
    private let totalMemory: UInt64 = sysctlValue("hw.memsize") ?? 0

    init() {
        previousTicks = Self.readCPUTicks()
    }

    func sample(date: Date = Date()) -> SystemSnapshot {
        let ticks = Self.readCPUTicks()
        var cpu = (system: 0.0, user: 0.0, idle: 100.0)
        if let ticks, let previous = previousTicks {
            cpu = CPUMath.percentages(previous: previous, current: ticks)
        }
        previousTicks = ticks ?? previousTicks

        let vm = Self.readVMCounts()
        let swap: xsw_usage? = sysctlStruct("vm.swapusage")
        let level: Int32 = sysctlValue("kern.memorystatus_level") ?? 100

        return SystemSnapshot(
            date: date,
            cpuSystem: cpu.system,
            cpuUser: cpu.user,
            cpuIdle: cpu.idle,
            appMemoryBytes: vm.map(MemoryMath.appMemoryBytes) ?? 0,
            wiredBytes: vm.map(MemoryMath.wiredBytes) ?? 0,
            compressedBytes: vm.map(MemoryMath.compressedBytes) ?? 0,
            totalMemoryBytes: totalMemory,
            swapUsedBytes: swap?.xsu_used ?? 0,
            swapTotalBytes: swap?.xsu_total ?? 0,
            availablePercent: Double(level)
        )
    }

    private static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks 인덱스: USER 0, SYSTEM 1, IDLE 2, NICE 3
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private static func readVMCounts() -> VMCounts? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMCounts(
            pageSize: UInt64(getpagesize()),
            internalPages: UInt64(info.internal_page_count),
            purgeablePages: UInt64(info.purgeable_count),
            wirePages: UInt64(info.wire_count),
            compressorPages: UInt64(info.compressor_page_count)
        )
    }
}

func sysctlValue<T: FixedWidthInteger>(_ name: String) -> T? {
    var value: T = 0
    var size = MemoryLayout<T>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

func sysctlStruct<T>(_ name: String) -> T? {
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }
    var size = MemoryLayout<T>.size
    guard sysctlbyname(name, pointer, &size, nil, 0) == 0 else { return nil }
    return pointer.pointee
}
