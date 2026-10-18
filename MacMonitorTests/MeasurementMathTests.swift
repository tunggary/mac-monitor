import Testing
@testable import MacMonitor

struct MeasurementMathTests {
    @Test func cpuPercentagesFromTickDelta() {
        let previous = CPUTicks(user: 1000, system: 500, idle: 8000, nice: 0)
        let current = CPUTicks(user: 1100, system: 550, idle: 8800, nice: 50)
        // 델타: user 100 + nice 50, system 50, idle 800 → 합 1000
        let result = CPUMath.percentages(previous: previous, current: current)
        #expect(abs(result.user - 15) < 1e-9)
        #expect(abs(result.system - 5) < 1e-9)
        #expect(abs(result.idle - 80) < 1e-9)
    }

    @Test func cpuPercentagesHandleCounterWrapAndNoDelta() {
        let previous = CPUTicks(user: 0xFFFF_FFF0, system: 0, idle: 0, nice: 0)
        let current = CPUTicks(user: 0x10, system: 0, idle: 0x20, nice: 0) // 32비트 틱이 감김
        let wrapped = CPUMath.percentages(previous: previous, current: current)
        #expect(abs(wrapped.user - 50) < 1e-9) // user 델타 0x20, idle 0x20
        #expect(CPUMath.percentages(previous: current, current: current).idle == 100)
    }

    @Test func memoryDefinitions() {
        let vm = VMCounts(pageSize: 16384, internalPages: 400_000, purgeablePages: 50_000, wirePages: 200_000, compressorPages: 300_000)
        #expect(MemoryMath.appMemoryBytes(vm) == 350_000 * 16384)
        #expect(MemoryMath.wiredBytes(vm) == 200_000 * 16384)
        #expect(MemoryMath.compressedBytes(vm) == 300_000 * 16384)

        let total: UInt64 = 16 * 1024 * 1024 * 1024
        let percent = MemoryMath.memoryPercent(
            appBytes: MemoryMath.appMemoryBytes(vm), wiredBytes: MemoryMath.wiredBytes(vm),
            compressedBytes: MemoryMath.compressedBytes(vm), totalBytes: total
        )
        #expect(abs(percent - Double(850_000 * 16384) / Double(total) * 100) < 1e-9)
    }

    @Test func pressureIsComplementOfAvailable() {
        let snapshot = SystemSnapshot(
            date: .now, cpuSystem: 10, cpuUser: 20, cpuIdle: 70,
            appMemoryBytes: 0, wiredBytes: 0, compressedBytes: 0, totalMemoryBytes: 1,
            swapUsedBytes: 0, swapTotalBytes: 0, availablePercent: 69
        )
        #expect(snapshot.pressurePercent == 31)
        #expect(snapshot.cpuBusy == 30)
    }

    @Test func machTimeConversionUsesTimebase() {
        // Apple Silicon: 125/3
        #expect(ProcessMath.nanoseconds(machTicks: 24_000_000, numer: 125, denom: 3) == 1_000_000_000)
        #expect(ProcessMath.nanoseconds(machTicks: 100, numer: 1, denom: 1) == 100)
    }

    @Test func processCPUPercentIsCoreRelative() {
        // 3초 동안 CPU 6초 → 200%
        let percent = ProcessMath.cpuPercent(
            previousCPUNanoseconds: 1_000_000_000, currentCPUNanoseconds: 7_000_000_000, wallNanoseconds: 3_000_000_000
        )
        #expect(abs(percent - 200) < 1e-9)
        #expect(ProcessMath.cpuPercent(previousCPUNanoseconds: 5, currentCPUNanoseconds: 1, wallNanoseconds: 10) == 0)
        #expect(ProcessMath.cpuPercent(previousCPUNanoseconds: 0, currentCPUNanoseconds: 1, wallNanoseconds: 0) == 0)
    }
}
