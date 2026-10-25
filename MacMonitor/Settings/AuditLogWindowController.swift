import AppKit
import SwiftUI

/// "AI 판정 기록" 창. 설정의 AI 판정 카드에서 연다. 단일 인스턴스이고, 닫으면 내용 뷰를 버린다(다시 열 때 새로 읽는다).
@MainActor
final class AuditLogWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: AuditLogView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "AI 판정 기록"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 640, height: 720))
            window.contentMinSize = NSSize(width: 480, height: 360)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}

private struct AuditLogView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            AuditLogSection(model: model)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .padding(.top, 20 + 28)
        }
        .frame(minWidth: 480, minHeight: 360)
        .background { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 0)).padding(.bottom, -60).ignoresSafeArea() }
        .ignoresSafeArea()
        .monospacedDigit()
        .preferredColorScheme(.dark)
    }
}
