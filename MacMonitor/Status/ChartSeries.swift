import Foundation

struct ChartPoint: Sendable, Equatable, Identifiable {
    /// 지금 기준 몇 초 전인가의 음수 (0 = 지금). 데이터가 적으면 오른쪽에만 그려진다.
    var x: Double
    var y: Double
    var id: Double { x }
}

enum ChartSeries {
    /// 1시간 범위의 최대 점 수 (그래프 폭 ~348 의 절반)
    static let hourMaxPoints = 174

    /// 최근 `rangeSamples`개(1초 간격)를 `maxPoints` 이하로 평균 다운샘플해 x 좌표를 붙인다.
    static func points(values: [Double], rangeSamples: Int, maxPoints: Int) -> [ChartPoint] {
        let window = Array(values.suffix(rangeSamples))
        guard !window.isEmpty else { return [] }
        let reduced = RingBuffer<Double>.downsample(window, maxPoints: maxPoints) { $0.reduce(0, +) / Double($0.count) }
        let span = Double(window.count - 1)
        let last = Double(max(reduced.count - 1, 1))
        return reduced.enumerated().map { index, value in
            ChartPoint(x: -span * (last - Double(index)) / last, y: value)
        }
    }
}
