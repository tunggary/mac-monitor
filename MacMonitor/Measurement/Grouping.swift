import Foundation

enum GroupKind: Sendable, Equatable {
    /// .app 번들 단위로 합산한 GUI 앱
    case app
    /// 터미널에서 띄운 CLI (명령 이름 + cwd 폴더)
    case cli
    /// 번들도 터미널도 없는 프로세스 (이름 단위)
    case process
}

/// 같은 실행 파일 이름끼리 묶은 하위 줄. `isOthers` 면 상위 3개 밖의 나머지를 합친 "그 외 N개".
struct SubGroup: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var processCount: Int
    var footprint: UInt64
    var cpuPercent: Double
    var pids: [Int32]
    var isOthers: Bool
    /// "그 외" 줄의 부가정보 (예: "Helper (GPU) 외")
    var othersHint: String?
}

struct AppGroup: Sendable, Equatable, Identifiable {
    var id: String
    var kind: GroupKind
    var displayName: String
    /// 아이콘용 .app 번들 경로 (CLI·프로세스 그룹은 nil)
    var bundlePath: String?
    var processCount: Int
    var footprint: UInt64
    var cpuPercent: Double
    var cwdFolder: String?
    var ports: [UInt16]
    var pids: [Int32]
    var subgroups: [SubGroup]
    /// 그룹 내 모든 pid 의 uid == 현재 uid 이고 이 앱 자신이 없을 때만 true
    var isTerminable: Bool
}

enum Grouping {
    static let terminalNames: Set<String> = [
        "terminal", "iterm", "iterm2", "cmux", "ghostty", "wezterm", "warp", "alacritty", "kitty",
    ]
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "login", "dash", "ksh", "tcsh", "csh"]
    static let visibleSubgroupCount = 3

    /// 실행 경로에서 가장 바깥 .app 번들 경로. 없으면 nil.
    static func outermostBundle(path: String?) -> String? {
        guard let path else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }

    static func bundleName(_ bundlePath: String) -> String {
        let last = (bundlePath as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    static func isTerminal(bundlePath: String) -> Bool {
        let name = bundleName(bundlePath).lowercased()
        return terminalNames.contains(name) || name.hasPrefix("cmux")
    }

    static func isShell(_ name: String) -> Bool {
        shellNames.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    static func cwdFolder(_ cwd: String?) -> String? {
        guard let cwd, cwd != "/" else { return nil }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }

    /// 순수 함수: 샘플 배열 → footprint 큰 순으로 정렬된 그룹 배열.
    static func group(_ samples: [ProcessSample], selfPid: Int32, currentUID: UInt32) -> [AppGroup] {
        let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        struct Draft {
            var kind: GroupKind
            var displayName: String
            var bundlePath: String?
            var cwdFolder: String?
            var members: [ProcessSample] = []
        }
        var drafts: [String: Draft] = [:]

        func add(_ sample: ProcessSample, id: String, kind: GroupKind, name: String, bundle: String?, cwd: String?) {
            drafts[id, default: Draft(kind: kind, displayName: name, bundlePath: bundle, cwdFolder: cwd)].members.append(sample)
        }
        func addToApp(_ sample: ProcessSample, bundle: String) {
            add(sample, id: bundle, kind: .app, name: bundleName(bundle), bundle: bundle, cwd: nil)
        }

        for sample in samples {
            if let own = outermostBundle(path: sample.path) {
                addToApp(sample, bundle: own)
            } else if let anchor = anchorBundle(for: sample, byPid: byPid) {
                if !isTerminal(bundlePath: anchor) {
                    addToApp(sample, bundle: anchor)
                } else if isShell(sample.name) {
                    addToApp(sample, bundle: anchor)
                } else {
                    let folder = cwdFolder(sample.cwd)
                    add(sample, id: "cli:\(sample.name)|\(folder ?? "")", kind: .cli, name: sample.name, bundle: nil, cwd: folder)
                }
            } else {
                add(sample, id: "proc:\(sample.name)", kind: .process, name: sample.name, bundle: nil, cwd: nil)
            }
        }

        return drafts.map { id, draft in
            let members = draft.members
            return AppGroup(
                id: id,
                kind: draft.kind,
                displayName: draft.displayName,
                bundlePath: draft.bundlePath,
                processCount: members.count,
                footprint: members.reduce(0) { $0 + ($1.footprint ?? 0) },
                cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
                cwdFolder: draft.cwdFolder,
                ports: Array(Set(members.flatMap(\.listenPorts))).sorted(),
                pids: members.map(\.pid).sorted(),
                subgroups: subgroups(of: members),
                isTerminable: members.allSatisfy { $0.uid == currentUID && $0.pid != selfPid }
            )
        }
        .sorted { ($0.footprint, $1.displayName) > ($1.footprint, $0.displayName) }
    }

    /// 자체 번들이 없는 프로세스의 소속 번들: responsible pid 의 번들 → 없으면 부모 체인에서 처음 만나는 번들.
    private static func anchorBundle(for sample: ProcessSample, byPid: [Int32: ProcessSample]) -> String? {
        if let responsible = sample.responsiblePid, let owner = byPid[responsible],
           let bundle = outermostBundle(path: owner.path) {
            return bundle
        }
        var current = sample
        for _ in 0..<8 {
            guard current.ppid > 1, let parent = byPid[current.ppid] else { return nil }
            if let bundle = outermostBundle(path: parent.path) { return bundle }
            current = parent
        }
        return nil
    }

    /// 같은 실행 파일 이름끼리 묶어 footprint 상위 3줄 + "그 외 N개".
    static func subgroups(of members: [ProcessSample]) -> [SubGroup] {
        let byName = Dictionary(grouping: members, by: \.name)
        let rows = byName.map { name, procs in
            SubGroup(
                id: name, name: name, processCount: procs.count,
                footprint: procs.reduce(0) { $0 + ($1.footprint ?? 0) },
                cpuPercent: procs.reduce(0) { $0 + $1.cpuPercent },
                pids: procs.map(\.pid).sorted(), isOthers: false, othersHint: nil
            )
        }
        .sorted { ($0.footprint, $1.name) > ($1.footprint, $0.name) }

        guard rows.count > visibleSubgroupCount else { return rows }
        let top = Array(rows.prefix(visibleSubgroupCount))
        let rest = rows.dropFirst(visibleSubgroupCount)
        let restCount = rest.reduce(0) { $0 + $1.processCount }
        let others = SubGroup(
            id: "others", name: "그 외 \(restCount)개", processCount: restCount,
            footprint: rest.reduce(0) { $0 + $1.footprint },
            cpuPercent: rest.reduce(0) { $0 + $1.cpuPercent },
            pids: rest.flatMap(\.pids).sorted(), isOthers: true,
            othersHint: rest.count > 1 ? "\(rest[rest.startIndex].name) 외" : rest[rest.startIndex].name
        )
        return top + [others]
    }
}
