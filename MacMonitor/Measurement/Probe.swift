import Darwin
import Foundation

/// `--probe-system N` / `--probe-procs` : UI 없이 측정값을 출력하는 검증용 모드.
enum Probe {
    private static func gb(_ bytes: UInt64) -> String { String(format: "%.2f", Double(bytes) / 1_073_741_824) }
    private static func mb(_ bytes: UInt64?) -> String { bytes.map { String(format: "%.0f", Double($0) / 1_048_576) } ?? "-" }

    static func runSystem(count: Int) {
        let sampler = SystemSampler()
        for _ in 0..<count {
            Thread.sleep(forTimeInterval: 1)
            let s = sampler.sample()
            print(String(
                format: "cpu sys %.1f%% user %.1f%% idle %.1f%% | mem %.1f%% (app %@ GB, wired %@ GB, compressed %@ GB) | swap used %@ GB | available %.0f%% | pressure %.0f%%",
                s.cpuSystem, s.cpuUser, s.cpuIdle, s.memoryPercent,
                gb(s.appMemoryBytes), gb(s.wiredBytes), gb(s.compressedBytes),
                gb(s.swapUsedBytes), s.availablePercent, s.pressurePercent
            ))
        }
    }

    static func runProcesses() {
        let sampler = ProcessSampler()
        var samples: [ProcessSample] = []
        for round in 1...2 {
            let start = Date()
            samples = sampler.sample()
            print(String(format: "sample %d: %d processes, took %.0f ms", round, samples.count, Date().timeIntervalSince(start) * 1000))
            if round == 1 { Thread.sleep(forTimeInterval: 3) }
        }

        let groups = Grouping.group(samples, selfPid: getpid(), currentUID: getuid())
        print("\n== top 15 groups by footprint (of \(groups.count)) ==")
        for g in groups.prefix(15) {
            let extra = [g.cwdFolder, g.ports.isEmpty ? nil : g.ports.map { ":\($0)" }.joined(separator: ",")]
                .compactMap { $0 }.joined(separator: " · ")
            print(String(
                format: "%@ [%@] procs %d  footprint %@ MB  cpu %.1f%%  terminable %@  %@",
                g.displayName, "\(g.kind)", g.processCount, mb(g.footprint), g.cpuPercent, g.isTerminable ? "Y" : "N", extra
            ))
            for sub in g.subgroups {
                print(String(
                    format: "    - %@ ×%d  %@ MB  cpu %.1f%%%@",
                    sub.name, sub.processCount, mb(sub.footprint), sub.cpuPercent,
                    sub.othersHint.map { "  (\($0))" } ?? ""
                ))
            }
        }

        print("\n== top 15 processes by footprint ==")
        let ranked = samples.sorted { ($0.footprint ?? 0) > ($1.footprint ?? 0) }
        for p in ranked.prefix(15) {
            print(String(
                format: "pid %d uid %d %@  footprint %@ MB  cpu %.1f%%  cwd %@  ports %@",
                p.pid, p.uid, p.name, mb(p.footprint), p.cpuPercent,
                Grouping.cwdFolder(p.cwd) ?? "-",
                p.listenPorts.isEmpty ? "-" : p.listenPorts.map { ":\($0)" }.joined(separator: ",")
            ))
        }
        let noFootprint = samples.filter { $0.footprint == nil }.count
        print("\n(footprint 없는 프로세스 \(noFootprint)개)")
    }
}
