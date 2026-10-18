import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let alertCenter = AlertCenter()
    private var statusController: StatusItemController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 단위 테스트 호스트로 뜬 경우에는 알림 권한 요청·로그인 항목 등록 같은 부작용을 내지 않는다.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        let settingsWindow = SettingsWindowController(model: model)
        self.settingsWindow = settingsWindow
        let status = StatusItemController(model: model, character: PartyParrot(), openSettings: { settingsWindow.show() })
        statusController = status

        alertCenter.onOpenPopover = { status.showPopover() }
        model.onAlert = { [alertCenter] message in alertCenter.post(message) }
        if !underTest {
            alertCenter.start()
            LoginItem.registerOnFirstLaunch()
        }
        model.start()
    }
}
