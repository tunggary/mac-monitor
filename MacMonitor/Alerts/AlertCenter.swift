import Foundation
import UserNotifications

/// 알림 응답을 받는 델리게이트. 메인 액터 밖에서 불리므로 값만 꺼내 핸들러로 넘긴다.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    let handler: @Sendable @MainActor (_ actionID: String, _ targetsJSON: String?) -> Void

    init(handler: @escaping @Sendable @MainActor (String, String?) -> Void) {
        self.handler = handler
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let actionID = response.actionIdentifier
        let json = response.notification.request.content.userInfo[AlertCenter.targetsKey] as? String
        await handler(actionID, json)
    }

    /// 앱이 활성 상태(팝오버가 열려 있을 때 등)여도 배너를 보인다.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

/// UNUserNotificationCenter 래퍼. 알림마다 "{이름} 종료" 액션이 다르므로 알림마다 카테고리를 등록한다.
@MainActor
final class AlertCenter {
    nonisolated static let targetsKey = "targets"
    private static let killPrefix = "kill."
    /// 아직 알림센터에 남아 있을 알림의 액션을 위해 최근 카테고리를 이만큼 유지한다.
    private static let categoryLimit = 20

    private let center = UNUserNotificationCenter.current()
    private var delegate: NotificationDelegate?
    private var categories: [UNNotificationCategory] = []
    /// 알림 본문(기본 액션) 클릭 → 팝오버 열기
    var onOpenPopover: (() -> Void)?

    func start() {
        let delegate = NotificationDelegate { [weak self] actionID, json in
            self?.handle(actionID: actionID, targetsJSON: json)
        }
        self.delegate = delegate
        center.delegate = delegate
        Task { [center] in
            _ = try? await center.requestAuthorization(options: [.alert])
        }
    }

    func post(_ message: AlertMessage) {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        if let data = try? JSONEncoder().encode(message.targets), let json = String(data: data, encoding: .utf8) {
            content.userInfo = [Self.targetsKey: json]
        }
        if !message.targets.isEmpty {
            let categoryID = "mm.\(UUID().uuidString)"
            let actions = message.targets.enumerated().map { index, target in
                UNNotificationAction(identifier: "\(Self.killPrefix)\(index)", title: "\(target.name) 종료", options: [])
            }
            categories.append(UNNotificationCategory(identifier: categoryID, actions: actions, intentIdentifiers: [], options: []))
            categories = Array(categories.suffix(Self.categoryLimit))
            center.setNotificationCategories(Set(categories))
            content.categoryIdentifier = categoryID
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func handle(actionID: String, targetsJSON: String?) {
        if actionID == UNNotificationDefaultActionIdentifier {
            onOpenPopover?()
        } else if actionID.hasPrefix(Self.killPrefix), let index = Int(actionID.dropFirst(Self.killPrefix.count)),
                  let data = targetsJSON?.data(using: .utf8),
                  let targets = try? JSONDecoder().decode([KillTarget].self, from: data),
                  targets.indices.contains(index) {
            // 알림 시점의 pid 이므로 신원(시작시간)이 같을 때만 SIGTERM
            ProcessKiller.terminate(targets[index].ids)
        }
    }
}
