import Testing
@testable import MacMonitor

struct RowTextTests {
    private func group(kind: GroupKind, count: Int, cwd: String? = nil, ports: [UInt16] = [], cpu: Double = 0) -> AppGroup {
        AppGroup(
            id: "g", kind: kind, displayName: "g", bundlePath: nil, processCount: count, footprint: 0, cpuPercent: cpu,
            cwdFolder: cwd, ports: ports, pids: [], subgroups: [], isTerminable: true
        )
    }

    @Test func cliSingleProcessHasNoCount() {
        #expect(RowText.detail(group: group(kind: .cli, count: 1, cwd: "web", ports: [3110])) == "web · :3110")
    }

    @Test func cliMergedProcessesAppendCount() {
        #expect(RowText.detail(group: group(kind: .cli, count: 3, cwd: "web", ports: [3110])) == "web · :3110 · 3개")
        #expect(RowText.detail(group: group(kind: .cli, count: 2, cwd: "web")) == "web · 2개")
        #expect(RowText.detail(group: group(kind: .cli, count: 2)) == "프로세스 2개")
    }

    @Test func appDetailAndDangerCPU() {
        #expect(RowText.detail(group: group(kind: .app, count: 42)) == "프로세스 42개")
        #expect(RowText.detail(group: group(kind: .app, count: 123, cpu: 112), showCPU: true) == "프로세스 123개 · CPU 112%")
    }

    @Test func subRowDetail() {
        let normal = SubGroup(id: "a", name: "a", processCount: 96, footprint: 0, cpuPercent: 0, pids: [], isOthers: false, othersHint: nil)
        let others = SubGroup(id: "others", name: "그 외 12개", processCount: 12, footprint: 0, cpuPercent: 0, pids: [], isOthers: true, othersHint: "Helper (GPU) 외")
        #expect(RowText.detail(sub: normal) == "96개")
        #expect(RowText.detail(sub: others) == "Helper (GPU) 외")
    }

    @Test func objectParticle() {
        #expect(Korean.objectParticle(for: "Aside") == "를")
        #expect(Korean.objectParticle(for: "카카오톡") == "을")
        #expect(Korean.objectParticle(for: "크롬") == "을")
        #expect(Korean.objectParticle(for: "파이어폭스") == "를")
        #expect(Korean.objectParticle(for: "next-server") == "를")
        #expect(Korean.objectParticle(for: "") == "를")
    }

    @Test func numberInput() {
        #expect(NumberInput.sanitize("12a3", allowsDecimal: false) == "123")
        #expect(NumberInput.sanitize("4.5", allowsDecimal: false) == "45")
        #expect(NumberInput.sanitize("4.5.6", allowsDecimal: true) == "4.56")
        #expect(NumberInput.sanitize("-3", allowsDecimal: true) == "3")
        #expect(NumberInput.positive("") == nil)
        #expect(NumberInput.positive("0") == nil)
        #expect(NumberInput.positive("4.5") == 4.5)
    }
}
