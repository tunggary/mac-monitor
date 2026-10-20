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
    /// 메뉴바에 그리는 크기(pt). 메뉴바 높이(22pt)에 꽉 차게.
    static let drawSize: CGFloat = 22

    let name = "파티 앵무새"
    let framesPerSecondRange = PartyParrot.speedRange
    private let cache: [MemoryLevel: [NSImage]]

    init(bundle: Bundle = .main) {
        let names: [(MemoryLevel, String)] = [(.normal, "green"), (.caution, "yellow"), (.danger, "coral")]
        var sources: [MemoryLevel: [CGImage]] = [:]
        for (level, color) in names {
            sources[level] = (1...Self.frameCount).compactMap { index in
                let file = String(format: "%@-%02d", color, index)
                guard let url = bundle.url(forResource: file, withExtension: "png"),
                      let image = NSImage(contentsOf: url) else { return nil }
                return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        }
        // 원본 위쪽이 투명 여백이라, 전 프레임의 그림 영역 합집합으로 잘라 메뉴바 높이에 맞춘다.
        // 프레임마다 따로 자르면 고개 까딱임이 흔들리므로 공통 영역 하나를 쓴다.
        let all = sources.values.flatMap { $0 }
        let crop = all.reduce(CGRect.null) { $0.union(Self.opaqueBounds($1)) }
        self.cache = sources.mapValues { $0.compactMap { Self.render($0, crop: crop, height: Self.drawSize) } }
    }

    func frames(for level: MemoryLevel) -> [NSImage] { cache[level] ?? [] }

    /// 알파가 있는 픽셀의 경계(왼쪽 위 원점, CGImage.cropping 좌표계).
    private static func opaqueBounds(_ image: CGImage) -> CGRect {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return CGRect(x: 0, y: 0, width: width, height: height) }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] > 12 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .null }
        // 비트맵 메모리의 첫 행이 이미지 위쪽이다.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 잘라낸 영역을 높이 기준으로 레티나(@2x) 비트맵에 그려 둔다. 템플릿 아님(색이 핵심).
    private static func render(_ source: CGImage, crop: CGRect, height points: CGFloat) -> NSImage? {
        guard let cropped = source.cropping(to: crop) else { return nil }
        let size = NSSize(width: (points * crop.width / crop.height).rounded(), height: points)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(cropped, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}
