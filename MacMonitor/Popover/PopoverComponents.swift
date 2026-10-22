import AppKit
import Charts
import SwiftUI

/// 상태 라벨: 7pt 점 + 11 semibold 텍스트. 정상은 텍스트가 secondary, 그 밖엔 상태색.
struct StatusLabel: View {
    let text: String
    let color: Color
    var tinted = true

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tinted ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
        }
        .fixedSize()
    }
}

/// 유리 위에 얹는 모듈 면: white 4% + 위쪽 0.5pt 하이라이트, 모서리 18
extension View {
    func glassModule(_ padding: EdgeInsets) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(Theme.moduleGlass, in: .rect(cornerRadius: Theme.moduleRadius, style: .continuous))
    }
}

/// 세그먼트 토글: 캡슐 트랙 white 6% padding 3 gap 2, 선택 thumb 캡슐 white 24%
struct SegmentedToggle<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var verticalPadding: CGFloat = 4

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.vertical, verticalPadding)
                        .padding(.horizontal, 11)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.thumbFill)
                                    .overlay(alignment: .top) {
                                        Capsule()
                                            .strokeBorder(
                                                LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center),
                                                lineWidth: 1
                                            )
                                    }
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.trackFill, in: Capsule())
    }
}

/// 영역(위→아래 그라디언트) + 선(1.5) 그래프. 축·격자는 숨긴다.
/// tint 가 nil 이면 정상(흰색 계열), 있으면 그 상태색.
struct MetricChart: View {
    struct Rule: Identifiable {
        let value: Double
        let color: Color
        var id: Double { value }
    }

    let points: [ChartPoint]
    var tint: Color?
    let yDomain: ClosedRange<Double>
    let rangeSamples: Int
    let height: CGFloat
    var rules: [Rule] = []
    let label: String

    private var lineColor: Color { tint ?? Theme.graphNeutralLine }
    private var areaTop: Color {
        tint.map { $0.opacity(Theme.graphTintedAreaTop) } ?? Color.white.opacity(Theme.graphNeutralAreaTop)
    }

    var body: some View {
        Chart {
            ForEach(rules) { rule in
                RuleMark(y: .value("기준", rule.value))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(rule.color.opacity(Theme.graphRuleOpacity))
            }
            ForEach(points) { point in
                AreaMark(x: .value("시간", point.x), y: .value("값", point.y))
                    .foregroundStyle(LinearGradient(colors: [areaTop, .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("시간", point.x), y: .value("값", point.y))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(lineColor)
            }
        }
        .chartXScale(domain: -Double(rangeSamples - 1)...0)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: height)
        .accessibilityLabel(label)
    }
}

/// 위험 배너의 경고 삼각형: 흰 삼각형 + 어두운 red 느낌표 (시안 viewBox 0 0 20 20)
struct WarningTriangle: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 20
            var triangle = Path()
            triangle.move(to: CGPoint(x: 10 * s, y: 2 * s))
            triangle.addLine(to: CGPoint(x: 18.5 * s, y: 17 * s))
            triangle.addLine(to: CGPoint(x: 1.5 * s, y: 17 * s))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(.white))
            var bar = Path()
            bar.move(to: CGPoint(x: 10 * s, y: 7.5 * s))
            bar.addLine(to: CGPoint(x: 10 * s, y: 11.5 * s))
            context.stroke(bar, with: .color(Theme.bannerMark), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
            context.fill(
                Path(ellipseIn: CGRect(x: (10 - 1.2) * s, y: (14.3 - 1.2) * s, width: 2.4 * s, height: 2.4 * s)),
                with: .color(Theme.bannerMark)
            )
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// .app 아이콘은 한 번만 가져와 캐시한다 (행이 1초마다 다시 그려지므로).
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundle path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}
