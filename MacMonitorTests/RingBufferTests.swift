import Testing
@testable import MacMonitor

struct RingBufferTests {
    @Test func overflowDropsOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        #expect(buffer.count == 3)
        #expect(buffer.elements == [3, 4, 5])
    }

    @Test func defaultCapacityIsOneHourOfSeconds() {
        #expect(RingBuffer<Int>().capacity == 3600)
    }

    @Test func recentRanges() {
        var buffer = RingBuffer<Int>()
        for value in 0..<4000 { buffer.append(value) }
        #expect(buffer.count == 3600)
        #expect(buffer.recent(.oneMinute) == Array(3940..<4000))
        #expect(buffer.recent(.tenMinutes).count == 600)
        #expect(buffer.recent(.tenMinutes).last == 3999)
        #expect(buffer.recent(.oneHour).count == 3600)
        #expect(buffer.recent(.oneHour).first == 400)
    }

    @Test func recentWhenNotFull() {
        var buffer = RingBuffer<Int>()
        for value in 0..<10 { buffer.append(value) }
        #expect(buffer.recent(.oneMinute) == Array(0..<10))
    }

    @Test func downsampleAverageAndMax() {
        var buffer = RingBuffer<Double>()
        for value in 0..<3600 { buffer.append(Double(value)) }
        let average = buffer.downsampledAverage(recent: 3600, maxPoints: 360)
        let maximum = buffer.downsampledMax(recent: 3600, maxPoints: 360)
        #expect(average.count == 360)
        #expect(average.first == 4.5) // 0...9 평균
        #expect(maximum.first == 9)
        #expect(maximum.last == 3599)
    }

    @Test func downsampleKeepsShortInputAndHandlesUnevenBuckets() {
        #expect(RingBuffer<Double>.downsample([1, 2, 3], maxPoints: 10) { $0[0] } == [1, 2, 3])
        let uneven = RingBuffer<Double>.downsample([1, 2, 3, 4, 5], maxPoints: 2) { $0.max() ?? 0 }
        #expect(uneven == [2, 5])
    }
}
