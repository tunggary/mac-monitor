import Foundation

/// 알림 액션 하나 = "{name} 종료" 버튼이 SIGTERM 을 보낼 대상 (알림 시점의 pid + 시작시간)
struct KillTarget: Sendable, Equatable, Codable {
    /// 알림 시점의 그룹 id (3초 뒤 생존 확인 때 현재 그룹과 맞춘다)
    var groupID: String
    var name: String
    var ids: [ProcessIdentity]
}

struct AlertMessage: Sendable, Equatable {
    var title: String
    var body: String
    var targets: [KillTarget]
    /// 알림음 재생 여부 (메모리 위험만 true)
    var playsSound = false
}

/// 알림 문구 만들기 (순수 함수). `identities` 로 종료 대상의 신원을 붙인다.
enum AlertMessages {
    static let actionLimit = 3

    /// 제목 "[위험] 메모리 — 스왑 12.7 GB", 본문 "Aside 20.7 GB · ego lite 3.9 GB · Claude 1.8 GB".
    /// `groups` 는 footprint 큰 순. 종료 버튼은 상위 3개 중 종료 가능한 앱만.
    static func memory(
        cause: DangerCause, swapBytes: UInt64, availablePercent: Double, groups: [AppGroup],
        identities: ([Int32]) -> [ProcessIdentity] = ProcessKiller.identities
    ) -> AlertMessage {
        let top = Array(groups.prefix(actionLimit))
        return AlertMessage(
            title: "[위험] 메모리 — \(Judgement.causeTitle(cause: cause, swapBytes: swapBytes, availablePercent: availablePercent))",
            body: top.map { "\($0.displayName) \(Format.memory($0.footprint))" }.joined(separator: " · "),
            targets: top.filter(\.isTerminable).map { KillTarget(groupID: $0.id, name: $0.displayName, ids: identities($0.terminablePids)) },
            playsSound: true
        )
    }

    /// 제목 "[주의] CPU 급증 — next-server 340%", 본문 "1pm_clinic_web-new-work-1018 · :3110 · 35초째"
    static func cpu(
        group: AppGroup, seconds: Int,
        identities: ([Int32]) -> [ProcessIdentity] = ProcessKiller.identities
    ) -> AlertMessage {
        AlertMessage(
            title: "[주의] CPU 급증 — \(group.displayName) \(Format.wholePercent(group.cpuPercent))",
            body: "\(RowText.detail(group: group)) · \(duration(seconds: seconds))째",
            targets: group.isTerminable ? [KillTarget(groupID: group.id, name: group.displayName, ids: identities(group.terminablePids))] : []
        )
    }

    /// 60초 미만은 "35초", 그 이상은 "N분" (스펙에는 "35초째" 예시만 있다)
    static func duration(seconds: Int) -> String {
        seconds < 60 ? "\(seconds)초" : "\(seconds / 60)분"
    }
}
