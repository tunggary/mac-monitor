import Foundation

/// 행에 붙는 사용 현황 태그. 정상인 그룹은 태그가 없다(nil).
enum UsageTag: String, Sendable, Equatable, Codable {
    case terminate = "종료 추천"
    case attention = "관심 필요"
}

/// 그룹 하나의 판정 입력. 규칙과 AI 판정이 같은 값을 본다.
struct UsageSignals: Sendable, Equatable {
    var groupID: String
    var displayName: String
    var kind: GroupKind
    /// 대표 프로세스(footprint 최대)의 실행 경로·인자 (가리기 전 원본)
    var executablePath: String?
    var arguments: [String]
    var cwd: String?
    var ports: [UInt16]
    /// 리슨 포트에 붙은 ESTABLISHED 연결 수 합
    var establishedConnections: Int
    var processCount: Int
    /// 같은 실행 파일 이름 중 가장 많은 것의 개수
    var sameNameMaxCount: Int
    /// 그룹에서 가장 오래된 프로세스의 실행 시간
    var uptimeSeconds: TimeInterval
    /// CPU 1% 미만 + 연결 0개가 이어진 시간 (모니터 시작 이후). 활동 중이면 0.
    var idleSeconds: TimeInterval
    var isOrphan: Bool
    /// 사라진 조상 이름 (예 "claude", "codex", "zsh"). 처음부터 launchd 였던 고아면 nil.
    var lostAncestor: String?
    var footprint: UInt64
    /// 30분 전 대비 footprint 증가율(%). 이력이 30분이 안 되면 nil.
    var footprintGrowthPercent: Double?
    /// 30분 동안 footprint 가 줄어든 적 없이 늘었는지
    var footprintMonotonic: Bool
    var cpuPercent: Double
    /// GUI 앱이 마지막으로 앞에 활성화된 지 경과. 모니터 시작 이후 한 번도 못 봤으면 (지금 - 모니터 시작).
    /// CLI·process 그룹은 nil. 활성화 정보는 AppModel 이 `enriched` 로 채운다.
    var lastActiveSeconds: TimeInterval?
    /// 모니터 시작 이후 활성화(앞에 옴)를 한 번이라도 봤는지. false 면 `lastActiveSeconds` 는 "최소 이만큼"이다.
    var activeSinceMonitorStart = false
    /// 그룹의 pid 중 하나라도 화면에 보이는 일반(layer 0) 창을 가졌는지. CLI·process 그룹은 nil.
    var hasVisibleWindow: Bool?
    /// 고아가 아닌 CLI·process 그룹에서, 대표 프로세스의 조상 체인에 지금 살아 있는 claude·codex·터미널·셸 이름 (에이전트 우선).
    var liveAncestor: String?
}

/// 규칙 1차 판정 결과
enum RuleOutcome: Sendable, Equatable {
    /// 태그 없음
    case none
    /// 규칙이 직접 붙인 태그. `.terminate` 는 AI 판정이 켜져 있으면 데이터 손실 검사를 거친다.
    case tag(UsageTag, reason: String)
    /// 판단 보류 → AI 판정 (꺼져 있으면 태그 없음)
    case ambiguous(reason: String)

    var reason: String? {
        switch self {
        case .none: nil
        case .tag(_, let reason), .ambiguous(let reason): reason
        }
    }
}
