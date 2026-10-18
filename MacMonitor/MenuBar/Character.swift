import AppKit

/// 메뉴바 캐릭터. 교체 가능하도록 이름 · 상태별 프레임 · 속도 범위만 노출한다.
@MainActor
protocol Character {
    var name: String { get }
    /// 메모리 상태별 프레임 배열(보통 10장)
    func frames(for level: MemoryLevel) -> [NSImage]
    /// 초당 프레임 수 범위 (CPU 낮음 ... CPU 높음)
    var framesPerSecondRange: ClosedRange<Double> { get }
}

enum CharacterSpeed {
    static let lowCPU = 10.0
    static let highCPU = 90.0

    /// CPU ≤ 10% → 범위 하한, ≥ 90% → 상한, 사이는 fps 선형 보간.
    static func framesPerSecond(cpuPercent: Double, range: ClosedRange<Double>) -> Double {
        let t = min(1, max(0, (cpuPercent - lowCPU) / (highCPU - lowCPU)))
        return range.lowerBound * (1 - t) + range.upperBound * t
    }
}

/// 파티 앵무새: 초록(정상) / 노랑(주의) / 코랄(위험) 각 10프레임.
/// 번들 리소스 PNG(128×128)를 시작 시 메뉴바 크기로 미리 줄여 캐시한다.
@MainActor
final class PartyParrot: Character {
    nonisolated static let frameCount = 10
    /// 10장 / 1.2초 ... 10장 / 0.35초
    nonisolated static let speedRange = (Double(frameCount) / 1.2)...(Double(frameCount) / 0.35)
    /// 메뉴바에 그리는 크기(pt). 시안은 24×24 버튼 안.
    static let drawSize: CGFloat = 18

    let name = "파티 앵무새"
    let framesPerSecondRange = PartyParrot.speedRange
    private let cache: [MemoryLevel: [NSImage]]

    init(bundle: Bundle = .main) {
        let names: [(MemoryLevel, String)] = [(.normal, "green"), (.caution, "yellow"), (.danger, "coral")]
        var cache: [MemoryLevel: [NSImage]] = [:]
        for (level, color) in names {
            cache[level] = (1...Self.frameCount).compactMap { index in
                let file = String(format: "%@-%02d", color, index)
                guard let url = bundle.url(forResource: file, withExtension: "png"),
                      let source = NSImage(contentsOf: url) else { return nil }
                return Self.resized(source, points: Self.drawSize)
            }
        }
        self.cache = cache
    }

    func frames(for level: MemoryLevel) -> [NSImage] { cache[level] ?? [] }

    /// 레티나(@2x) 비트맵으로 미리 그려 둔다. 템플릿 아님(색이 핵심).
    private static func resized(_ source: NSImage, points: CGFloat) -> NSImage {
        let pixels = Int(points * 2)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: points, height: points), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}
