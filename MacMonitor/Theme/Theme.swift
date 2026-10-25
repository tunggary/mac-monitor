import SwiftUI

/// Liquid Glass 스타일 토큰. 유리 자체엔 색이 없고, 색은 의미가 있을 때만 시스템 색으로 쓴다.
enum Theme {
    // MARK: 의미 색
    static let ok = Color.green
    static let warn = Color.yellow
    static let danger = Color.red
    /// 선택·포커스
    static let accent = Color.accentColor

    /// 태그 배지 배경 (의미 색 위에 얹는 투명도)
    static let badgeFillOpacity = 0.2

    // MARK: 면 (유리 위에 얹는 흰색 투명도)
    static let expandedRowFill = Color.white.opacity(0.07)
    static let hoverFill = Color.white.opacity(0.08)
    static let trackFill = Color.white.opacity(0.06)
    static let thumbFill = Color.white.opacity(0.24)
    static let iconHoverFill = Color.white.opacity(0.14)
    static let iconPlaceholderFill = Color.white.opacity(0.14)
    static let divider = Color.white.opacity(0.10)
    static let inputBorder = Color.white.opacity(0.10)
    static let insetFill = Color.black.opacity(0.22)
    static let scrollIndicator = Color.white.opacity(0.35)
    static let placeholderFill = Color.white.opacity(0.03)
    static let placeholderBorder = Color.white.opacity(0.20)

    // MARK: 위험 배너
    static let bannerFill = Color.red.opacity(0.55)
    /// 배너 경고 삼각형의 느낌표 (어두운 red)
    static let bannerMark = Color(red: 0.77, green: 0.15, blue: 0.16)

    // MARK: 그래프
    /// 정상 상태의 선 (= .primary 상당)
    static let graphNeutralLine = Color.white.opacity(0.85)
    static let graphNeutralAreaTop = 0.28
    static let graphTintedAreaTop = 0.32
    static let graphRuleOpacity = 0.6

    // MARK: 유리 — 제어 센터처럼 바깥 판과 모듈 모두 맑은(clear) 유리.
    // clear 는 배경 밝기에 적응하지 않아 밝은 배경에서 하얗게 뜬다. 판 뒤에 검은 dim 층을 깔아 막는다.
    // (regular 는 밝기엔 적응하지만 배경을 뿌옇게 갈아 탁해 보인다.)
    static let popoverRadius: CGFloat = 26
    static let popoverGlass: Glass = .clear
    static let popoverDim = Color.black.opacity(0.5)
    static let moduleGlass: Glass = .clear

    // MARK: 크기
    static let moduleRadius: CGFloat = 18
}
