import Foundation
import ServiceManagement

/// 로그인 시 자동 실행 (SMAppService.mainApp)
enum LoginItem {
    private static let didAutoRegisterKey = "loginItem.didAutoRegister"

    /// 체크박스 표시: 등록됨 또는 시스템 설정에서 승인 대기 중
    static var isOn: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// 첫 실행에서 한 번만 등록한다 (기본 켬). 실패해도 다시 시도하지 않는다.
    static func registerOnFirstLaunch(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: didAutoRegisterKey) else { return }
        defaults.set(true, forKey: didAutoRegisterKey)
        try? setEnabled(true)
    }
}
