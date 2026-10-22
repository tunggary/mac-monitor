import SwiftUI

/// 상위 앱 한 행. 클릭하면 그 자리에서 펼친다(한 번에 하나).
/// 목록은 고정 높이 스크롤 영역 안에 있어서, 펼쳐도 팝오버 높이와 하단 바는 변하지 않는다.
struct AppRowView: View {
    let model: AppModel
    let group: AppGroup
    let dot: RowDot

    private var expanded: Bool { model.expandedID == group.id }
    private var groupKey: String { KillCoordinator.groupKey(group.id) }

    private func toggle() { model.expandedID = expanded ? nil : group.id }

    var body: some View {
        if expanded {
            panel
        } else {
            RowHeader(group: group, dot: dot, sort: model.sort, expanded: false, onToggle: toggle, onKill: killGroup)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            RowHeader(group: group, dot: dot, sort: model.sort, expanded: true, onToggle: toggle, onKill: killGroup)
            ForEach(group.subgroups) { sub in
                SubRowView(sort: model.sort, sub: sub, canKill: sub.isTerminable) {
                    model.kill.terminate(
                        key: KillCoordinator.subKey(group.id, sub.id), groupID: group.id, name: sub.name, pids: sub.pids
                    )
                }
                confirmBox(key: KillCoordinator.subKey(group.id, sub.id))
            }
            confirmBox(key: groupKey)
        }
        .padding(.bottom, 8)
        .background(Theme.expandedRowFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func confirmBox(key: String) -> some View {
        if let entry = model.kill.entries[key], entry.needsConfirm {
            ForceKillBox(
                name: entry.name,
                onCancel: { model.kill.cancel(key: key) },
                onForce: { model.kill.forceKill(key: key) }
            )
        }
    }

    private func killGroup() {
        model.kill.terminate(key: groupKey, groupID: group.id, name: group.displayName, pids: group.terminablePids)
    }
}

/// 상위 앱 한 줄. 펼친 상태에서는 × 대신 "종료" 텍스트 버튼.
private struct RowHeader: View {
    let group: AppGroup
    let dot: RowDot
    let sort: AppSort
    let expanded: Bool
    let onToggle: () -> Void
    let onKill: () -> Void

    @State private var hovering = false

    /// 정상 행은 점을 그리지 않는다 (자리는 유지해 값 정렬이 흔들리지 않게).
    private var dotColor: Color {
        switch dot {
        case .ok: .clear
        case .warn: Theme.warn
        case .danger: Theme.danger
        }
    }

    // 위험 시 원인(코랄) 행만 CPU 를 덧붙인다 (시안 Danger)
    private var detail: String { RowText.detail(group: group, showCPU: dot == .danger) }

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
                    .font(.system(size: 13, weight: dot == .danger ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(value)
                .font(.system(size: 13, weight: dot == .danger ? .semibold : .medium))
                .foregroundStyle(.primary)
                .fixedSize()
            killButton
        }
        .padding(EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 6))
        .background(hovering && !expanded ? Theme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(group.displayName), \(detail), \(value)")
        .accessibilityHint(expanded ? "접기" : "하위 프로세스 펼치기")
        .accessibilityAction(named: expanded ? "접기" : "펼치기", onToggle)
    }

    @ViewBuilder
    private var killButton: some View {
        if !group.isTerminable {
            Color.clear.frame(width: 28, height: 28)
        } else {
            // 펼쳐도 같은 × (앱 전체 종료)
            KillXButton(size: 28, iconSize: 11, action: onKill)
                .accessibilityLabel("\(group.displayName) 종료")
        }
    }
}

/// 원형 × 버튼. hover 시 white 14% 원 + primary.
private struct KillXButton: View {
    let size: CGFloat
    let iconSize: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: size, height: size)
                .background(hovering ? Theme.iconHoverFill : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 펼친 영역의 하위 묶음 줄. 이름 시작 위치(왼쪽 48)에 맞춘다.
private struct SubRowView: View {
    let sort: AppSort
    let sub: SubGroup
    let canKill: Bool
    let onKill: () -> Void

    private var value: String {
        switch sort {
        case .memory: Format.memory(sub.footprint)
        case .cpu: Format.wholePercent(sub.cpuPercent)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(sub.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(RowText.detail(sub: sub))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize()
            if canKill {
                KillXButton(size: 26, iconSize: 9.5, action: onKill)
                .accessibilityLabel("\(sub.name) 종료")
            } else {
                Color.clear.frame(width: 26, height: 26)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 48, bottom: 6, trailing: 8))
    }
}

/// 인라인 강제종료 확인 박스 (시안 Danger)
private struct ForceKillBox: View {
    let name: String
    let onCancel: () -> Void
    let onForce: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(name)\(Korean.objectParticle(for: name)) 강제종료할까요?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text("일반 종료에 응답하지 않아요. 저장 안 된 작업은 사라져요.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .padding(.top, 2)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Text("취소")
                        .font(.system(size: 12))
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                Button(action: onForce) {
                    Text("강제종료")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(.red)
            }
            .padding(.top, 8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.insetFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(EdgeInsets(top: 8, leading: 48, bottom: 0, trailing: 8))
        .accessibilityElement(children: .contain)
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
                    Theme.iconPlaceholderFill
                    Text(String(group.displayName.prefix(1)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }
}
