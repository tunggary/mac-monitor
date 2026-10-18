import AppKit
import SwiftUI

/// 프레임 교체를 레이어 contents 대입만으로 하는 뷰. NSButton.image 를 바꾸면 버튼 전체가 다시 그려져 비싸다.
private final class FrameView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.contentsGravity = .center
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ image: CGImage, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        layer?.contents = image
        CATransaction.commit()
    }
}

/// 메뉴바 앵무새 + 클릭 시 팝오버 토글.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let character: any Character
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var frameIndex = 0
    private var shownLevel: MemoryLevel = .normal
    private var frameTimer: Timer?
    private let frameView = FrameView(frame: .zero)
    /// 상태별 CGImage 캐시 (NSImage → CGImage 변환은 시작 후 한 번만)
    private var cgFrames: [MemoryLevel: [CGImage]] = [:]

    init(model: AppModel, character: any Character) {
        self.model = model
        self.character = character
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
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
                frameView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            button.target = self
            button.action = #selector(togglePopover)
        }
        showFrame()
        updateAccessibility()
        model.onUpdate = { [weak self] in self?.modelDidUpdate() }
        scheduleNextFrame()
    }

    // MARK: 프레임 애니메이션 — 한 장씩 교체만 하고, 다음 간격은 매번 현재 CPU 로 다시 정한다.

    private func scheduleNextFrame() {
        let cpu = model.latest?.cpuBusy ?? 0
        let interval = 1 / CharacterSpeed.framesPerSecond(cpuPercent: cpu, range: character.framesPerSecondRange)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func advanceFrame() {
        frameIndex += 1
        showFrame()
        scheduleNextFrame()
    }

    private func showFrame() {
        if cgFrames[shownLevel] == nil {
            // 비트맵 rep 의 원본 픽셀(@2x)을 그대로 쓴다. cgImage(forProposedRect:) 는 pt 크기로 줄여 돌려준다.
            cgFrames[shownLevel] = character.frames(for: shownLevel).compactMap {
                ($0.representations.first as? NSBitmapImageRep)?.cgImage
            }
        }
        guard let frames = cgFrames[shownLevel], !frames.isEmpty else { return }
        frameView.show(frames[frameIndex % frames.count], scale: statusItem.button?.window?.backingScaleFactor ?? 2)
    }

    private func modelDidUpdate() {
        guard model.memoryLevel != shownLevel else { return }
        shownLevel = model.memoryLevel
        showFrame()
        updateAccessibility()
    }

    private func updateAccessibility() {
        let label = shownLevel == .danger ? "mac-monitor 열기, 메모리 위험" : "mac-monitor 열기"
        statusItem.button?.setAccessibilityLabel(label)
    }

    // MARK: 팝오버 — 열 때만 뷰를 만들고, 닫으면 버려서 SwiftUI 갱신이 돌지 않게 한다.

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        let controller = NSHostingController(rootView: PopoverView(model: model))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
