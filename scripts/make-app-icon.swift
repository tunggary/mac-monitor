#!/usr/bin/env swift
// 번개 앱 아이콘 생성 (일회성). 사용: swift scripts/make-app-icon.swift
// 시안(Notification.dc.html): 38px 칸 · radius 9 · 20px 번개 → 칸 대비 번개 20/38, 모서리 9/38.
// macOS 아이콘 그리드: 1024 캔버스에 824 둥근 사각형(여백 100).
import AppKit

let outputDirectory = "MacMonitor/Assets.xcassets/AppIcon.appiconset"
let background = NSColor(srgbRed: 0x15 / 255, green: 0x17 / 255, blue: 0x1D / 255, alpha: 1)
let brand = NSColor(srgbRed: 0x7C / 255, green: 0x85 / 255, blue: 0xFF / 255, alpha: 1)

func render(pixels: Int) -> Data {
    let canvas = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let tile = canvas * 824 / 1024
    let inset = (canvas - tile) / 2
    let radius = tile * 9 / 38
    background.setFill()
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: tile, height: tile), xRadius: radius, yRadius: radius).fill()

    // 번개: viewBox 0 0 20 20 (y 아래로 증가) → 타일 중앙에 tile * 20/38 크기
    let boltSize = tile * 20 / 38
    let origin = (canvas - boltSize) / 2
    let scale = boltSize / 20
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin + x * scale, y: origin + (20 - y) * scale) }
    let bolt = NSBezierPath()
    bolt.move(to: point(11, 2))
    bolt.line(to: point(4, 11.5))
    bolt.line(to: point(9.5, 11.5))
    bolt.line(to: point(8.5, 18))
    bolt.line(to: point(16, 8))
    bolt.line(to: point(10.5, 8))
    bolt.close()
    brand.setFill()
    bolt.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(point: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (point, scale) in sizes {
    let filename = "icon_\(point)x\(point)@\(scale)x.png"
    try render(pixels: point * scale).write(to: URL(fileURLWithPath: "\(outputDirectory)/\(filename)"))
    images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(point)x\(point)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: "\(outputDirectory)/Contents.json"))
print("generated \(sizes.count) icons")
