import Foundation
import Testing
@testable import MacMonitor

struct GroupingTests {
    private let me: UInt32 = 501
    private let selfPid: Int32 = 99_999
    private let mb: UInt64 = 1_048_576

    private let aside = "/Applications/Aside.app/Contents/MacOS/Aside"
    private let asideHelper = "/Applications/Aside.app/Contents/Frameworks/Aside Helper (Renderer).app/Contents/MacOS/Aside Helper (Renderer)"
    private let cmux = "/Applications/cmux.app/Contents/MacOS/cmux"

    private func group(_ samples: [ProcessSample]) -> [AppGroup] {
        Grouping.group(samples, selfPid: selfPid, currentUID: me)
    }

    @Test func outermostBundleIsFound() {
        #expect(Grouping.outermostBundle(path: asideHelper) == "/Applications/Aside.app")
        #expect(Grouping.outermostBundle(path: "/usr/bin/zsh") == nil)
        #expect(Grouping.outermostBundle(path: nil) == nil)
    }

    @Test func asideHelpersMergeIntoOneApp() {
        var samples = [ProcessSample(pid: 10, name: "Aside", path: aside, footprint: 500 * mb)]
        for index in 0..<5 {
            samples.append(ProcessSample(
                pid: Int32(20 + index), name: "Aside Helper (Renderer)", path: asideHelper,
                footprint: 100 * mb, cpuPercent: 10, responsiblePid: 10
            ))
        }
        let groups = group(samples)
        #expect(groups.count == 1)
        #expect(groups[0].displayName == "Aside")
        #expect(groups[0].kind == .app)
        #expect(groups[0].bundlePath == "/Applications/Aside.app")
        #expect(groups[0].processCount == 6)
        #expect(groups[0].footprint == 1000 * mb)
        #expect(groups[0].cpuPercent == 50)
        #expect(groups[0].isTerminable)
    }

    @Test func nextServersSplitByCwdUnderTerminal() {
        let samples = [
            ProcessSample(pid: 1, name: "cmux", path: cmux, footprint: 100 * mb),
            ProcessSample(pid: 2, name: "next-server", path: "/opt/homebrew/bin/node", cwd: "/work/a", footprint: 300 * mb, listenPorts: [3110], responsiblePid: 1),
            ProcessSample(pid: 3, name: "next-server", path: "/opt/homebrew/bin/node", cwd: "/work/b", footprint: 200 * mb, responsiblePid: 1),
        ]
        let groups = group(samples)
        let cli = groups.filter { $0.kind == .cli }
        #expect(cli.count == 2)
        #expect(cli.map(\.cwdFolder) == ["a", "b"])
        #expect(cli[0].ports == [3110])
        #expect(groups.first { $0.kind == .app }?.processCount == 1)
    }

    @Test func nextServersWithSameCwdMergeIntoOneLine() {
        let samples = [
            ProcessSample(pid: 1, name: "cmux", path: cmux),
            ProcessSample(pid: 2, name: "next-server", path: "/opt/homebrew/bin/node", cwd: "/work/a", footprint: 300 * mb, listenPorts: [3110], responsiblePid: 1),
            ProcessSample(pid: 3, name: "next-server", path: "/opt/homebrew/bin/node", cwd: "/work/a", footprint: 200 * mb, listenPorts: [3111], responsiblePid: 1),
        ]
        let cli = group(samples).filter { $0.kind == .cli }
        #expect(cli.count == 1)
        #expect(cli[0].processCount == 2)
        #expect(cli[0].footprint == 500 * mb)
        #expect(cli[0].ports == [3110, 3111])
    }

    @Test func shellsMergeIntoTerminal() {
        let samples = [
            ProcessSample(pid: 1, name: "cmux", path: cmux, footprint: 100 * mb),
            ProcessSample(pid: 2, name: "zsh", path: "/bin/zsh", cwd: "/work/a", footprint: 5 * mb, responsiblePid: 1),
            ProcessSample(pid: 3, name: "-zsh", path: "/bin/zsh", footprint: 5 * mb, responsiblePid: 1),
            ProcessSample(pid: 4, name: "login", path: "/usr/bin/login", footprint: 1 * mb, responsiblePid: 1),
        ]
        let groups = group(samples)
        #expect(groups.count == 1)
        #expect(groups[0].displayName == "cmux")
        #expect(groups[0].processCount == 4)
    }

    @Test func cliWithoutResponsibleFallsBackToParentChain() {
        let samples = [
            ProcessSample(pid: 10, name: "cmux", path: cmux),
            ProcessSample(pid: 11, ppid: 10, name: "zsh", path: "/bin/zsh"),
            ProcessSample(pid: 12, ppid: 11, name: "vite", path: "/opt/homebrew/bin/node", cwd: "/work/web"),
        ]
        let cli = group(samples).filter { $0.kind == .cli }
        #expect(cli.count == 1)
        #expect(cli[0].cwdFolder == "web")
    }

    @Test func otherUidGroupIsNotTerminable() {
        let samples = [
            ProcessSample(pid: 0, uid: 0, name: "kernel_task", footprint: 3000 * mb),
            ProcessSample(pid: 5, uid: 88, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", footprint: 700 * mb),
            ProcessSample(pid: 6, name: "node", path: "/opt/homebrew/bin/node", footprint: 10 * mb),
        ]
        let byName = Dictionary(uniqueKeysWithValues: group(samples).map { ($0.displayName, $0) })
        #expect(byName["kernel_task"]?.isTerminable == false)
        #expect(byName["WindowServer"]?.isTerminable == false)
        #expect(byName["node"]?.isTerminable == true)
    }

    @Test func mixedUidGroupKillsOnlyMyProcesses() {
        let samples = [
            ProcessSample(pid: 1, name: "Aside", path: aside, footprint: 300 * mb),
            ProcessSample(pid: 2, uid: 0, name: "Aside Helper", path: asideHelper, footprint: 200 * mb),
            ProcessSample(pid: 3, name: "Aside Helper (Renderer)", path: asideHelper, footprint: 100 * mb),
        ]
        let g = group(samples)[0]
        #expect(g.isTerminable)
        #expect(g.terminablePids == [1, 3])
        let byName = Dictionary(uniqueKeysWithValues: g.subgroups.map { ($0.name, $0) })
        #expect(byName["Aside"]?.isTerminable == true)
        #expect(byName["Aside Helper"]?.isTerminable == false)
        #expect(byName["Aside Helper (Renderer)"]?.isTerminable == true)
    }

    @Test func groupWithOnlyOtherUidHasNoTerminablePids() {
        let samples = [ProcessSample(pid: 2, uid: 0, name: "Aside Helper", path: asideHelper)]
        let g = group(samples)[0]
        #expect(!g.isTerminable)
        #expect(g.terminablePids.isEmpty)
    }

    @Test func subgroupWithSelfPidIsNotTerminable() {
        let samples = [
            ProcessSample(pid: selfPid, name: "mac-monitor", path: "/Applications/mac-monitor.app/Contents/MacOS/mac-monitor"),
            ProcessSample(pid: 7, name: "helper", path: "/Applications/mac-monitor.app/Contents/Helpers/helper"),
        ]
        let g = group(samples)[0]
        #expect(g.terminablePids == [7])
        #expect(g.subgroups.first { $0.name == "mac-monitor" }?.isTerminable == false)
    }

    @Test func selfIsNotTerminable() {
        let samples = [ProcessSample(pid: selfPid, name: "mac-monitor", path: "/Applications/mac-monitor.app/Contents/MacOS/mac-monitor")]
        #expect(group(samples)[0].isTerminable == false)
        #expect(group(samples)[0].subgroups[0].isTerminable == false)
    }

    @Test func subgroupsTopThreePlusOthers() {
        var samples: [ProcessSample] = []
        func add(_ name: String, count: Int, each: UInt64) {
            for _ in 0..<count {
                samples.append(ProcessSample(pid: Int32(100 + samples.count), name: name, path: asideHelper, footprint: each * mb))
            }
        }
        add("Renderer", count: 4, each: 100) // 400
        add("Plugin", count: 2, each: 150)   // 300
        add("Main", count: 1, each: 200)     // 200
        add("Helper (GPU)", count: 1, each: 50)
        add("Crashpad", count: 3, each: 1)

        let subs = group(samples)[0].subgroups
        #expect(subs.map(\.name) == ["Renderer", "Plugin", "Main", "그 외 4개"])
        #expect(subs[0].processCount == 4)
        #expect(subs[3].isOthers)
        #expect(subs[3].processCount == 4)
        #expect(subs[3].footprint == 53 * mb)
        #expect(subs[3].othersHint == "Helper (GPU) 외")
    }

    @Test func subgroupsWithThreeOrFewerNamesHaveNoOthers() {
        let samples = [
            ProcessSample(pid: 1, name: "a", path: aside, footprint: 1),
            ProcessSample(pid: 2, name: "b", path: aside, footprint: 2),
        ]
        let subs = group(samples)[0].subgroups
        #expect(subs.map(\.name) == ["b", "a"])
        #expect(!subs.contains { $0.isOthers })
    }

    @Test func groupsSortedByFootprint() {
        let samples = [
            ProcessSample(pid: 1, name: "small", path: "/usr/bin/small", footprint: 1 * mb),
            ProcessSample(pid: 2, name: "big", path: "/usr/bin/big", footprint: 9 * mb),
            ProcessSample(pid: 3, name: "nofootprint", path: "/usr/bin/nofootprint"),
        ]
        #expect(group(samples).map(\.displayName) == ["big", "small", "nofootprint"])
    }
}

struct DisplayNameTests {
    @Test func versionNameUsesFolderAboveVersionsContainer() {
        let path = "/Users/me/.local/share/claude/versions/2.1.302"
        #expect(Grouping.displayName(name: "2.1.302", path: path) == "claude")
    }

    @Test func versionNameSkipsNumericAndContainerFolders() {
        #expect(Grouping.displayName(name: "1.0", path: "/opt/tool/releases/current/bin/1.0") == "tool")
        #expect(Grouping.displayName(name: "3.2.1", path: "/opt/tool/3.2/3.2.1") == "tool")
    }

    @Test func normalNamesAreUntouched() {
        #expect(Grouping.displayName(name: "node", path: "/opt/homebrew/bin/node") == "node")
        #expect(Grouping.displayName(name: "next-server", path: nil) == "next-server")
        #expect(Grouping.displayName(name: "python3.12", path: "/usr/bin/python3.12") == "python3.12")
    }

    @Test func versionNameWithoutUsablePathKeepsName() {
        #expect(Grouping.displayName(name: "2.1.302", path: nil) == "2.1.302")
        #expect(Grouping.displayName(name: "2.1.302", path: "/versions/2.1.302") == "2.1.302")
    }
}

struct DockerVMGroupingTests {
    private let vm = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    private let docker = "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization"

    private func group(_ samples: [ProcessSample]) -> [AppGroup] {
        Grouping.group(samples, selfPid: 99_999, currentUID: 501)
    }

    @Test func vmJoinsDockerWhenDockerVirtualizationRuns() {
        let groups = group([
            ProcessSample(pid: 10, name: "com.docker.virtualization", path: docker, footprint: 10),
            ProcessSample(pid: 11, name: "com.apple.Virtualization.VirtualMachine", path: vm, footprint: 4000),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].id == "/Applications/Docker.app")
        #expect(groups[0].processCount == 2)
    }

    @Test func vmStaysSeparateWithoutDocker() {
        let groups = group([ProcessSample(pid: 11, name: "com.apple.Virtualization.VirtualMachine", path: vm, footprint: 4000)])
        #expect(groups.count == 1)
        #expect(groups[0].kind == .process)
    }
}

struct ProcessArgsTests {
    private func buffer(argc: Int32, path: String, padding: Int, args: [String], env: [String] = []) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
        bytes += Array(path.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for item in args + env { bytes += Array(item.utf8) + [0] }
        return bytes
    }

    @Test func parsesArgvAndSkipsEnvironment() {
        let bytes = buffer(argc: 3, path: "/bin/node", padding: 3, args: ["node", "server.js", "--port=3000"], env: ["HOME=/Users/x"])
        #expect(ProcessArgs.parse(bytes) == ["node", "server.js", "--port=3000"])
    }

    @Test func truncatedOrEmptyBuffers() {
        #expect(ProcessArgs.parse([]) == [])
        #expect(ProcessArgs.parse([1, 0, 0]) == [])
        #expect(ProcessArgs.parse(buffer(argc: 0, path: "/x", padding: 0, args: [])) == [])
        #expect(ProcessArgs.parse(buffer(argc: 5, path: "/x", padding: 1, args: ["a", "b"])) == ["a", "b"])
    }
}
