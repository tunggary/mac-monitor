import AppKit
import Charts
import SwiftUI

/// 상태 칩: 배경 16%, padding 3×8, radius 10, 12 semibold
struct Chip: View {
    let text: String
    let color: ThemeColor

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color.color)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(color.opacity(Theme.chipBackgroundOpacity).color, in: RoundedRectangle(cornerRadius: 10))
            .fixedSize()
    }
}

/// 세그먼트 토글: surface-2 배경 radius 7 padding 2 gap 2, 선택 = surface-3 + accent 글자 semibold
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
                        .foregroundStyle(selected ? Theme.accent.color : Theme.text2.color)
                        .padding(.vertical, verticalPadding)
                        .padding(.horizontal, 10)
                        .background(selected ? Theme.surface3.color : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.surface2.color, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SectionDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line.color).frame(height: 1)
    }
}

/// 영역(24%) + 선(1.5px) 그래프. 축·격자는 숨긴다.
struct MetricChart: View {
    struct Rule: Identifiable {
        let value: Double
        let color: ThemeColor
        var id: Double { value }
    }

    let points: [ChartPoint]
    let color: ThemeColor
    let yDomain: ClosedRange<Double>
    let rangeSamples: Int
    let height: CGFloat
    var rules: [Rule] = []
    let label: String

    var body: some View {
        Chart {
            ForEach(rules) { rule in
                RuleMark(y: .value("기준", rule.value))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(rule.color.opacity(0.7).color)
            }
            ForEach(points) { point in
                AreaMark(x: .value("시간", point.x), y: .value("값", point.y))
                    .foregroundStyle(color.opacity(Theme.graphAreaOpacity).color)
                LineMark(x: .value("시간", point.x), y: .value("값", point.y))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(color.color)
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

/// 위험 배너의 경고 삼각형 (시안 viewBox 0 0 20 20)
struct WarningTriangle: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 20
            var triangle = Path()
            triangle.move(to: CGPoint(x: 10 * s, y: 2 * s))
            triangle.addLine(to: CGPoint(x: 18.5 * s, y: 17 * s))
            triangle.addLine(to: CGPoint(x: 1.5 * s, y: 17 * s))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(Theme.danger.color))
            var bar = Path()
            bar.move(to: CGPoint(x: 10 * s, y: 7.5 * s))
            bar.addLine(to: CGPoint(x: 10 * s, y: 11.5 * s))
            context.stroke(bar, with: .color(Theme.surface.color), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
            context.fill(
                Path(ellipseIn: CGRect(x: (10 - 1.2) * s, y: (14.3 - 1.2) * s, width: 2.4 * s, height: 2.4 * s)),
                with: .color(Theme.surface.color)
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
