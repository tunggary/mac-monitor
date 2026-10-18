import Foundation

/// 시계열 구간. 샘플 간격이 1초이므로 구간 = 최근 N개 샘플.
enum TimeRange: Int, Sendable, CaseIterable {
    case oneMinute = 60
    case tenMinutes = 600
    case oneHour = 3600

    var sampleCount: Int { rawValue }
}

/// 고정 용량 링버퍼. 가득 차면 가장 오래된 값을 덮어쓴다. 디스크 저장 없음.
struct RingBuffer<Element: Sendable>: Sendable {
    static var defaultCapacity: Int { 3600 }

    let capacity: Int
    private var storage: [Element] = []
    private var head = 0 // 가득 찼을 때 가장 오래된 원소의 위치

    init(capacity: Int = RingBuffer.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int { storage.count }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// 오래된 순서 → 최신 순서.
    var elements: [Element] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    /// 가장 최근 `count`개 (오래된 순서).
    func recent(_ count: Int) -> [Element] {
        let all = elements
        return Array(all.suffix(max(0, count)))
    }

    func recent(_ range: TimeRange) -> [Element] {
        recent(range.sampleCount)
    }

    /// 최근 `count`개를 최대 `maxPoints`점으로 줄인다. 균등 구간으로 나눠 `combine`(평균·최대 등)으로 합친다.
    func downsampled(
        recent count: Int,
        maxPoints: Int,
        combine: ([Element]) -> Element
    ) -> [Element] {
        RingBuffer.downsample(recent(count), maxPoints: maxPoints, combine: combine)
    }

    static func downsample(_ values: [Element], maxPoints: Int, combine: ([Element]) -> Element) -> [Element] {
        guard maxPoints > 0 else { return [] }
        guard values.count > maxPoints else { return values }
        var result: [Element] = []
        result.reserveCapacity(maxPoints)
        for bucket in 0..<maxPoints {
            let start = bucket * values.count / maxPoints
            let end = (bucket + 1) * values.count / maxPoints
            result.append(combine(Array(values[start..<end])))
        }
        return result
    }
}

extension RingBuffer where Element == Double {
    func downsampledAverage(recent count: Int, maxPoints: Int) -> [Double] {
        downsampled(recent: count, maxPoints: maxPoints) { $0.reduce(0, +) / Double($0.count) }
    }

    func downsampledMax(recent count: Int, maxPoints: Int) -> [Double] {
        downsampled(recent: count, maxPoints: maxPoints) { $0.max() ?? 0 }
    }
}
