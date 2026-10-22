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

/// 키 입력은 안 받지만 스크롤·hover 이벤트를 위해 key 가 될 수 있는 테두리 없는 패널.
private final class PopoverPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// preferredContentSize 가 바뀔 때 알려 주는 호스팅 컨트롤러.
private final class SizeReportingHostingController<Content: View>: NSHostingController<Content> {
    var onSizeChange: ((NSSize) -> Void)?
    override var preferredContentSize: NSSize {
        didSet { if preferredContentSize != oldValue { onSizeChange?(preferredContentSize) } }
    }
}

/// 메뉴바 앵무새 + 클릭 시 유리 패널 토글.
@MainActor
final class StatusItemController: NSObject {
    /// 앵무새 하단 여백(pt)
    private static let bottomPadding: CGFloat = 3
    private static let log = Logger(subsystem: "com.mac-monitor", category: "animation")
    private let model: AppModel
    private let openSettings: () -> Void
    private let character: any Character
    private let statusItem: NSStatusItem
    private var panel: PopoverPanel?
    private var hosting: SizeReportingHostingController<PopoverView>?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
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

    // MARK: 패널 — 열 때만 뷰를 만들고, 닫으면 버려서 SwiftUI 갱신이 돌지 않게 한다.

    private static let panelGap: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    @objc private func togglePopover() {
        if panel != nil {
            closePopover()
        } else {
            showPopover()
        }
    }

    /// 알림 클릭 등 밖에서도 팝오버를 열 수 있게 한다.
    func showPopover() {
        guard panel == nil, let button = statusItem.button, button.window != nil else { return }
        let controller = SizeReportingHostingController(rootView: PopoverView(model: model, openSettings: { [weak self] in
            self?.closePopover()
            self?.openSettings()
        }))
        controller.sizingOptions = [.preferredContentSize]
        controller.view.layoutSubtreeIfNeeded()
        controller.onSizeChange = { [weak self] size in self?.resizePanel(to: size, animate: true) }

        let panel = PopoverPanel(
            contentRect: NSRect(origin: .zero, size: controller.view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 창 그림자는 사각 윤곽으로 그려져 둥근 유리 모서리 밖에 검은 모서리가 비친다. 그림자는 유리 자체에 맡긴다.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onCancel = { [weak self] in self?.closePopover() }
        panel.contentView = controller.view

        self.panel = panel
        hosting = controller
        resizePanel(to: controller.view.fittingSize, animate: false)
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors()
    }

    /// 상태 아이템 아래 중앙, 화면 밖이면 안으로. 높이가 바뀌어도 위쪽을 고정한다.
    private func resizePanel(to size: NSSize, animate: Bool) {
        guard let panel, let button = statusItem.button, let buttonWindow = button.window,
              size.width > 0, size.height > 0 else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let top = buttonFrame.minY - Self.panelGap
        var x = buttonFrame.midX - size.width / 2
        x = min(x, visible.maxX - Self.screenMargin - size.width)
        x = max(x, visible.minX + Self.screenMargin)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true, animate: animate && panel.isVisible)
    }

    private func statusButtonFrame() -> NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func installDismissMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        // 상태 아이템 클릭은 시스템 쪽 창이라 전역 이벤트로 온다 — 토글 액션이 처리하게 둔다.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.statusButtonFrame().contains(NSEvent.mouseLocation) else { return }
                self.closePopover()
            }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            // 패널 안, 그리고 상태 아이템(토글 액션이 처리)은 그대로 통과시킨다.
            if event.window !== panel, event.window !== self.statusItem.button?.window { self.closePopover() }
            return event
        }) { monitors.append(local) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopover() {
        guard let panel else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        statusItem.button?.highlight(false)
        panel.orderOut(nil)
        panel.contentView = nil
        hosting = nil
        self.panel = nil
    }
}
