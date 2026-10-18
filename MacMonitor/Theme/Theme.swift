import AppKit
import SwiftUI

/// 색 하나를 SwiftUI Color 와 NSColor 양쪽으로 쓰기 위한 값.
struct ThemeColor: Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    func opacity(_ value: Double) -> ThemeColor {
        ThemeColor(red: red, green: green, blue: blue, alpha: value)
    }

    private init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Ink Indigo 팔레트. 화면은 아래 "의미 토큰"만 참조하고 원시 색은 직접 쓰지 않는다.
enum Theme {
    // MARK: 원시 색 (연함 / 기본 / 진함)
    enum Raw {
        static let brandLight = ThemeColor(hex: 0xB9BEFF)
        static let brand = ThemeColor(hex: 0x7C85FF)
        static let brandDeep = ThemeColor(hex: 0x545DE8)

        static let greenLight = ThemeColor(hex: 0xB4EDD2)
        static let green = ThemeColor(hex: 0x6FD6A8)
        static let greenDeep = ThemeColor(hex: 0x2FA877)

        static let yellowLight = ThemeColor(hex: 0xFBE3A8)
        static let yellow = ThemeColor(hex: 0xF5C96A)
        static let yellowDeep = ThemeColor(hex: 0xC08A1E)

        static let alertLight = ThemeColor(hex: 0xFFB0A6)
        static let alert = ThemeColor(hex: 0xFF7A6B)
        static let alertDeep = ThemeColor(hex: 0xD2453A)
    }

    // MARK: 중립
    static let ground = ThemeColor(hex: 0x0D0E12)
    static let surface = ThemeColor(hex: 0x15171D)
    static let surface2 = ThemeColor(hex: 0x1E2129)
    static let surface3 = ThemeColor(hex: 0x2A2E38)
    static let text = ThemeColor(hex: 0xECEEF3)
    static let text2 = ThemeColor(hex: 0x9AA0AD)
    static let text3 = ThemeColor(hex: 0x7D8391)
    static let line = ThemeColor(hex: 0xFFFFFF, alpha: 0.08)
    static let lineStrong = ThemeColor(hex: 0xFFFFFF, alpha: 0.14)
    static let menubar = ThemeColor(hex: 0x08090C)

    // MARK: 의미 토큰
    static let cpu = Raw.brand
    static let mem = Raw.brand
    static let swap = Raw.brandLight
    static let ok = Raw.green
    static let warn = Raw.yellow
    static let danger = Raw.alert
    /// 선택·토글·포커스
    static let accent = Raw.brand
    /// 강제종료 버튼 면 (글자는 흰색)
    static let forceKillFill = Raw.alertDeep
    static let forceKillText = ThemeColor(hex: 0xFFFFFF)

    // MARK: 투명도 규칙
    /// 상태 칩 배경
    static let chipBackgroundOpacity = 0.16
    /// 그래프 면(AreaMark)
    static let graphAreaOpacity = 0.24
}
