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
        .background(Theme.surface2.color, in: RoundedRectangle(cornerRadius: 10))
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

    private var dotColor: ThemeColor {
        switch dot {
        case .ok: Theme.ok
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
        } else if expanded {
            Button(action: onKill) {
                Text("종료")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text.color)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.surface3.color, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.displayName) 종료")
        } else {
            Button(action: onKill) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3.color)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.displayName) 종료")
        }
    }
}

/// 펼친 영역의 하위 묶음 줄. 이름 시작 위치(왼쪽 46px)에 맞춘다.
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
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(RowText.detail(sub: sub))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2.color)
                .fixedSize()
            if canKill {
                Button(action: onKill) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.text3.color)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(sub.name) 종료")
            } else {
                Color.clear.frame(width: 26, height: 26)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 46, bottom: 6, trailing: 8))
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
                .foregroundStyle(Theme.text.color)
            Text("일반 종료에 응답하지 않아요. 저장 안 된 작업은 사라져요.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2.color)
                .lineSpacing(2)
                .padding(.top, 2)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Text("취소")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text.color)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.surface3.color, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                Button(action: onForce) {
                    Text("강제종료")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.forceKillText.color)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.forceKillFill.color, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.5).color, lineWidth: 1))
        .padding(EdgeInsets(top: 8, leading: 46, bottom: 0, trailing: 8))
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
