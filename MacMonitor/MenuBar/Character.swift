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

/// 파티 앵무새: 흰 테두리만 그린 10프레임. 메모리 상태로 색을 바꾸지 않는다.
/// 번들 리소스 PNG(128×128)를 시작 시 메뉴바 크기로 미리 줄여 캐시한다.
@MainActor
final class PartyParrot: Character {
    nonisolated static let frameCount = 10
    /// 10장 / 1.2초 ... 10장 / 0.35초
    nonisolated static let speedRange = (Double(frameCount) / 1.2)...(Double(frameCount) / 0.35)
    /// 메뉴바에 그리는 크기(pt). 메뉴바 높이(22pt)보다 살짝 작게.
    static let drawSize: CGFloat = 18

    let name = "파티 앵무새"
    let framesPerSecondRange = PartyParrot.speedRange
    private let frames: [NSImage]

    init(bundle: Bundle = .main) {
        // 메모리 상태와 상관없이 같은 프레임(흰 테두리)을 쓴다.
        let sources = Self.outlineSources(bundle: bundle)
        // 원본 위쪽이 투명 여백이라, 전 프레임의 그림 영역 합집합으로 잘라 메뉴바 높이에 맞춘다.
        // 프레임마다 따로 자르면 고개 까딱임이 흔들리므로 공통 영역 하나를 쓴다.
        let crop = sources.reduce(CGRect.null) { $0.union(Self.opaqueBounds($1)) }
        self.frames = sources.compactMap { Self.render($0, crop: crop, height: Self.drawSize) }
    }

    /// 원본 프레임에서 검은 테두리만 흰색으로 남기고 몸통·부리 등 나머지는 투명하게 만든 10장(128px).
    static func outlineSources(bundle: Bundle = .main) -> [CGImage] {
        (1...frameCount).compactMap { index in
            guard let url = bundle.url(forResource: String(format: "green-%02d", index), withExtension: "png"),
                  let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            return outlined(image)
        }
    }

    /// 어두운 픽셀(테두리) → 흰색, 그 밖 → 투명. 알파는 원본 유지.
    private static func outlined(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = pixels[i + 3]
            guard alpha > 0 else { continue }
            // premultiplied 값을 알파로 나눠 원래 밝기(0~1)를 본다.
            let luma = (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / Double(alpha)
            let keep: UInt8 = luma < 0.25 ? alpha : 0
            pixels[i] = keep; pixels[i + 1] = keep; pixels[i + 2] = keep; pixels[i + 3] = keep
        }
        return context.makeImage()
    }

    func frames(for level: MemoryLevel) -> [NSImage] { frames }

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
