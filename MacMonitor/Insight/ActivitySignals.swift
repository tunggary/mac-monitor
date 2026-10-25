import AppKit
import CoreGraphics
import Foundation

extension UsageSignals {
    /// GUI 앱 그룹에 활동 신호(마지막 활성화·보이는 창)를 채운다. CLI·process 그룹은 그대로 둔다.
    /// - activations: 번들 경로(가장 바깥 .app) → 마지막으로 앞에 활성화된 시각
    /// - visiblePids: 화면에 보이는 layer 0 창을 가진 pid 집합
    func enriched(
        bundlePath: String?, pids: [Int32], activations: [String: Date], monitorStart: Date,
        visiblePids: Set<Int32>, now: Date
    ) -> UsageSignals {
        guard kind == .app else { return self }
        var result = self
        if let bundlePath, let date = activations[bundlePath] {
            result.lastActiveSeconds = max(0, now.timeIntervalSince(date))
            result.activeSinceMonitorStart = true
        } else {
            result.lastActiveSeconds = max(0, now.timeIntervalSince(monitorStart))
            result.activeSinceMonitorStart = false
        }
        result.hasVisibleWindow = pids.contains { visiblePids.contains($0) }
        return result
    }
}

/// NSWorkspace 앞 앱 활성화를 번들 경로별로 기록한다 (모니터 시작 이후만). 앱 수명 동안 살아 있어 옵저버를 해제하지 않는다.
@MainActor
final class ActivationRecorder {
    let startDate: Date
    private(set) var activations: [String: Date] = [:]

    init(now: Date = Date()) {
        startDate = now
        if let path = NSWorkspace.shared.frontmostApplication?.bundleURL?.path { activations[path] = now }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path
            MainActor.assumeIsolated {
                if let path { self?.activations[path] = Date() }
            }
        }
    }
}

/// 화면에 보이는 창을 가진 pid. 창 이름은 읽지 않아 화면 기록 권한이 필요 없다.
/// 호출 비용이 있어 TTL 동안 결과를 재사용한다. 상태를 가지므로 ProcessMonitor actor 안에서만 쓴다.
final class VisibleWindowProbe {
    static let ttl: TimeInterval = 15

    private var cached: Set<Int32> = []
    private var fetchedAt: Date?

    func visiblePids(now: Date) -> Set<Int32> {
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.ttl { return cached }
        cached = Self.read()
        fetchedAt = now
        return cached
    }

    static func read() -> Set<Int32> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return pids(from: list)
    }

    /// kCGWindowOwnerPID·kCGWindowLayer 만 본다. layer 0 이 일반 앱 창 (메뉴바·Dock·오버레이는 0 이 아니다).
    static func pids(from windows: [[String: Any]]) -> Set<Int32> {
        var result = Set<Int32>()
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int else { continue }
            result.insert(Int32(truncatingIfNeeded: pid))
        }
        return result
    }
}
