import Foundation

/// 상위 앱 행·알림의 부가정보 문구 (순수 함수)
enum RowText {
    /// CLI: "cwd · :포트" (합친 프로세스 2개 이상이면 " · N개"), 정보가 없으면 "프로세스 N개".
    /// 앱·프로세스: "프로세스 N개" (`showCPU` 면 " · CPU 112%").
    static func detail(group: AppGroup, showCPU: Bool = false) -> String {
        switch group.kind {
        case .cli:
            var parts = [group.cwdFolder, group.ports.first.map { ":\($0)" }].compactMap { $0 }
            if parts.isEmpty { return "프로세스 \(group.processCount)개" }
            if group.processCount >= 2 { parts.append("\(group.processCount)개") }
            return parts.joined(separator: " · ")
        case .app, .process:
            let base = "프로세스 \(group.processCount)개"
            return showCPU ? "\(base) · CPU \(Format.wholePercent(group.cpuPercent))" : base
        }
    }

    /// 하위 줄: "그 외"는 othersHint, 그 밖에는 "N개"
    static func detail(sub: SubGroup) -> String {
        if sub.isOthers, let hint = sub.othersHint { return hint }
        return "\(sub.processCount)개"
    }
}
