import AppKit
import os
import SwiftUI

/// 앵무새 프레임 애니메이션을 Core Animation 렌더 서버에 맡기는 뷰.
/// CAKeyframeAnimation(contents, discrete)을 걸어 두면 프레임마다 앱이 깨어나지 않는다.
private final class FrameView: NSView {
    /// 현재 애니메이션의 한 바퀴 길이(초)와 레이어 시간 기준 시작점. 교체 시 위상을 이어받는 데 쓴다.
    private(set) var duration: CFTimeInterval?
    private var origin: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // 아래쪽에 붙이고, 하단 여백은 버튼 제약(bottomPadding)으로 준다.
        layer?.contentsGravity = .bottom
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// frames 를 duration 초에 한 바퀴 돌게 건다. 이미 돌고 있었다면 현재 위상(0..<1)에서 이어서 돈다.
    func play(_ frames: [CGImage], duration: CFTimeInterval, scale: CGFloat) {
        guard let layer, let first = frames.first else { return }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        var phase = 0.0
        if let current = self.duration {
            phase = ((now - origin) / current).truncatingRemainder(dividingBy: 1)
        }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = now - phase * duration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        layer.contents = first
        layer.add(animation, forKey: "frames")
        CATransaction.commit()

        self.duration = duration
        origin = animation.beginTime
    }
}

/// 메뉴바 앵무새 + 클릭 시 팝오버 토글.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    /// 앵무새 하단 여백(pt)
    private static let bottomPadding: CGFloat = 3
    private static let log = Logger(subsystem: "com.mac-monitor", category: "animation")
    private let model: AppModel
    private let openSettings: () -> Void
    private let character: any Character
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var shownLevel: MemoryLevel = .normal
    private let frameView = FrameView(frame: .zero)
    /// 상태별 CGImage 캐시 (NSImage → CGImage 변환은 시작 후 한 번만)
    private var cgFrames: [MemoryLevel: [CGImage]] = [:]

    init(model: AppModel, character: any Character, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.character = character
        statusItem = NSStatusBar.system.statusItem(withLength: 32)
        super.init()

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        if let button = statusItem.button {
            button.addSubview(frameView)
            NSLayoutConstraint.activate([
                frameView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                frameView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                frameView.topAnchor.constraint(equalTo: button.topAnchor),
                frameView.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -Self.bottomPadding),
            ])
            button.target = self
            button.action = #selector(togglePopover)
        }
        updateAnimation()
        updateAccessibility()
        model.onUpdate = { [weak self] in self?.modelDidUpdate() }
    }

    // MARK: 프레임 애니메이션 — 렌더 서버가 돌리고, 속도·색이 의미 있게 바뀔 때만 애니메이션을 교체한다.

    /// 한 바퀴 길이가 이 비율 이상 바뀌어야 애니메이션을 교체한다 (1초마다 갈아끼우는 비용을 피한다).
    private static let durationChangeThreshold = 0.05

    private func targetDuration() -> CFTimeInterval {
        let cpu = model.latest?.cpuBusy ?? 0
        let fps = CharacterSpeed.framesPerSecond(cpuPercent: cpu, range: character.framesPerSecondRange)
        return Double(framesFor(shownLevel).count) / fps
    }

    private func framesFor(_ level: MemoryLevel) -> [CGImage] {
        if cgFrames[level] == nil {
            // 비트맵 rep 의 원본 픽셀(@2x)을 그대로 쓴다. cgImage(forProposedRect:) 는 pt 크기로 줄여 돌려준다.
            cgFrames[level] = character.frames(for: level).compactMap {
                ($0.representations.first as? NSBitmapImageRep)?.cgImage
            }
        }
        return cgFrames[level] ?? []
    }

    private func updateAnimation(levelChanged: Bool = true) {
        let frames = framesFor(shownLevel)
        guard !frames.isEmpty else { return }
        let duration = targetDuration()
        if !levelChanged, let current = frameView.duration,
           abs(duration - current) / current < Self.durationChangeThreshold { return }
        frameView.play(frames, duration: duration, scale: statusItem.button?.window?.backingScaleFactor ?? 2)
        Self.log.debug("animation duration \(duration, format: .fixed(precision: 3))s level \(String(describing: self.shownLevel), privacy: .public)")
    }

    private func modelDidUpdate() {
        let levelChanged = model.memoryLevel != shownLevel
        if levelChanged {
            shownLevel = model.memoryLevel
            updateAccessibility()
        }
        updateAnimation(levelChanged: levelChanged)
    }

    private func updateAccessibility() {
        let label = shownLevel == .danger ? "mac-monitor 열기, 메모리 위험" : "mac-monitor 열기"
        statusItem.button?.setAccessibilityLabel(label)
    }

    // MARK: 팝오버 — 열 때만 뷰를 만들고, 닫으면 버려서 SwiftUI 갱신이 돌지 않게 한다.

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    /// 알림 클릭 등 밖에서도 팝오버를 열 수 있게 한다.
    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        let controller = NSHostingController(rootView: PopoverView(model: model, openSettings: { [weak self] in
            self?.popover.performClose(nil)
            self?.openSettings()
        }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
