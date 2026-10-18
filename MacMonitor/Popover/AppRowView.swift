import SwiftUI

/// 상위 앱 한 행. 행 펼침·× 동작은 다음 단계 — 지금은 자리만 둔다.
struct AppRowView: View {
    let group: AppGroup
    let dot: RowDot
    let sort: AppSort

    private var dotColor: ThemeColor {
        switch dot {
        case .ok: Theme.ok
        case .warn: Theme.warn
        case .danger: Theme.danger
        }
    }

    private var detail: String {
        switch group.kind {
        case .cli:
            let parts = [group.cwdFolder, group.ports.first.map { ":\($0)" }].compactMap { $0 }
            return parts.isEmpty ? "프로세스 \(group.processCount)개" : parts.joined(separator: " · ")
        case .app, .process:
            // 위험 시 원인(코랄) 행만 CPU 를 덧붙인다 (시안 Danger)
            let base = "프로세스 \(group.processCount)개"
            return dot == .danger ? "\(base) · CPU \(Format.wholePercent(group.cpuPercent))" : base
        }
    }

    private var value: String {
        switch sort {
        case .memory: Format.memory(group.footprint)
        case .cpu: Format.wholePercent(group.cpuPercent)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(group: group)
            VStack(alignment: .leading, spacing: 0) {
                Text(group.displayName)
                    .font(.system(size: 13, weight: dot == .danger ? .semibold : .regular))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Circle().fill(dotColor.color).frame(width: 8, height: 8)
            Text(value)
                .font(.system(size: 13, weight: dot == .danger ? .semibold : .regular))
                .foregroundStyle(dot == .danger ? Theme.danger.color : Theme.text.color)
                .fixedSize()
            killButton
        }
        .padding(8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var killButton: some View {
        if group.isTerminable {
            Button {
                // 다음 단계: SIGTERM
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3.color)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.displayName) 종료")
        } else {
            Color.clear.frame(width: 28, height: 28)
        }
    }
}

private struct AppIcon: View {
    let group: AppGroup

    var body: some View {
        Group {
            if let path = group.bundlePath {
                Image(nsImage: IconCache.icon(forBundle: path))
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    Theme.surface3.color
                    Text(String(group.displayName.prefix(1)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text2.color)
                }
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
