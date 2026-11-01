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
        installEditMenu()

        let settingsWindow = SettingsWindowController(model: model)
        self.settingsWindow = settingsWindow
        let status = StatusItemController(model: model, character: PartyParrot(), openSettings: { settingsWindow.show() })
        statusController = status

        alertCenter.onOpenPopover = { status.showPopover() }
        alertCenter.onKill = { [model] target in model.terminateFromAlert(target) }
        model.onForceKillPrompt = { status.showPopover() }
        model.onAlert = { [alertCenter] message in alertCenter.post(message) }
        if !underTest {
            alertCenter.start()
            LoginItem.registerOnFirstLaunch()
        }
        model.start()
    }

    /// 메뉴바 앱(LSUIElement)은 메인 메뉴가 없어 ⌘C·⌘V 등이 입력칸에 닿지 않는다.
    /// 화면에 보이지 않는 편집 메뉴를 달아 단축키를 살린다.
    private func installEditMenu() {
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem()) // 첫 항목은 앱 메뉴 자리
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
