import SwiftUI

/// 아이콘 클릭 시 뜨는 팝오버 내용. 폭 380, 다크 고정.
struct PopoverView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.memoryLevel == .danger {
                DangerBanner(model: model)
            }
            SystemHeader(model: model)
            CPUSection(model: model)
            SectionDivider()
            MemorySection(model: model)
            SwapSection(model: model)
            SectionDivider()
            TopAppsSection(model: model)
            FooterBar()
        }
        .padding(16)
        .frame(width: 380)
        .background(Theme.surface.color)
        .monospacedDigit()
        .preferredColorScheme(.dark)
    }
}

private struct DangerBanner: View {
    let model: AppModel

    private var title: String {
        guard let latest = model.latest else { return "메모리 위험" }
        switch model.dangerCause {
        case .availableMemory: return "메모리 위험 — 사용 가능 \(Format.wholePercent(latest.availablePercent))"
        default: return "메모리 위험 — 스왑 \(Format.gb(latest.swapUsedBytes))"
        }
    }

    private var message: String {
        let minutes = model.dangerSince.map { Judgement.dangerMinutes(since: $0, now: Date()) } ?? 1
        let settings = model.settings
        var text: String
        switch model.dangerCause {
        case .availableMemory:
            text = "사용 가능 메모리가 기준 \(Format.wholePercent(settings.availableDangerPercent)) 아래로 \(minutes)분째 내려가 있어요."
        default:
            text = "경고 기준 \(Format.thresholdGB(settings.swapDangerGB))를 \(minutes)분째 넘고 있어요."
        }
        if let top = model.topMemoryGroup {
            text += " 가장 큰 원인은 \(top.displayName)(\(Format.memory(top.footprint)))예요."
        }
        return text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WarningTriangle().padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.danger.opacity(Theme.chipBackgroundOpacity).color, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct SystemHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack {
            Text("시스템")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text2.color)
            Spacer()
            SegmentedToggle(
                options: [(TimeRange.oneMinute, "1분"), (.tenMinutes, "10분"), (.oneHour, "1시간")],
                selection: $model.range
            )
        }
    }
}

private extension TimeRange {
    var label: String {
        switch self {
        case .oneMinute: "1분"
        case .tenMinutes: "10분"
        case .oneHour: "1시간"
        }
    }
}

private struct CPUSection: View {
    let model: AppModel

    var body: some View {
        let _ = model.tick
        let snapshot = model.latest
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CPU \(Text(Format.percent(snapshot?.cpuBusy ?? 0)).foregroundStyle(Theme.cpu.color))")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                Spacer()
                if model.isCPUCaution {
                    Chip(text: "CPU 주의", color: Theme.warn)
                } else {
                    Chip(text: "CPU 정상", color: Theme.ok)
                }
            }
            Text("시스템 \(Format.percent(snapshot?.cpuSystem ?? 0)) · 사용자 \(Format.percent(snapshot?.cpuUser ?? 0)) · 대기 \(Format.percent(snapshot?.cpuIdle ?? 0))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2.color)
            MetricChart(
                points: model.chartPoints(.cpu), color: Theme.cpu, yDomain: 0...100,
                rangeSamples: model.range.sampleCount, height: 56,
                label: "최근 \(model.range.label) CPU 사용률 그래프"
            )
        }
    }
}

private struct MemorySection: View {
    let model: AppModel

    private var chip: (text: String, color: ThemeColor) {
        let pressure = Format.wholePercent(model.latest?.pressurePercent ?? 0)
        switch model.memoryLevel {
        case .normal: return ("압력 정상 \(pressure)", Theme.ok)
        case .caution: return ("압력 주의 \(pressure)", Theme.warn)
        case .danger: return ("압력 위험 \(pressure)", Theme.danger)
        }
    }

    var body: some View {
        let _ = model.tick
        let snapshot = model.latest
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("메모리 \(Text(Format.percent(snapshot?.memoryPercent ?? 0)).foregroundStyle(Theme.mem.color))")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                Spacer()
                Chip(text: chip.text, color: chip.color)
            }
            HStack(alignment: .top, spacing: 8) {
                MemoryFigure(label: "앱 메모리", value: Format.gb(snapshot?.appMemoryBytes ?? 0))
                MemoryFigure(label: "와이어드", value: Format.gb(snapshot?.wiredBytes ?? 0))
                MemoryFigure(label: "압축됨", value: Format.gb(snapshot?.compressedBytes ?? 0))
            }
            MetricChart(
                points: model.chartPoints(.memory), color: Theme.mem, yDomain: 0...100,
                rangeSamples: model.range.sampleCount, height: 48,
                label: "최근 \(model.range.label) 메모리 사용률 그래프"
            )
        }
    }
}

private struct MemoryFigure: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text2.color)
            Text(value).font(.system(size: 14)).foregroundStyle(Theme.text.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SwapSection: View {
    let model: AppModel

    var body: some View {
        let _ = model.tick
        let settings = model.settings
        let swapBytes = model.latest?.swapUsedBytes ?? 0
        let overDanger = Double(swapBytes) > settings.swapDangerBytes
        let points = model.chartPoints(.swapGB)
        let yMax = Judgement.swapYMaxGB(dangerGB: settings.swapDangerGB, observedMaxGB: points.map(\.y).max() ?? 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("스왑 \(Text(Format.gb(swapBytes)).foregroundStyle(Theme.swap.color))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                Spacer()
                Text("\(Text("주의 \(Format.thresholdGB(settings.swapCautionGB))").foregroundStyle(Theme.warn.color)) · \(Text(overDanger ? "위험 \(Format.thresholdGB(settings.swapDangerGB)) 초과" : "위험 \(Format.thresholdGB(settings.swapDangerGB))").foregroundStyle(Theme.danger.color).fontWeight(overDanger ? .semibold : .regular))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2.color)
            }
            MetricChart(
                points: points, color: Theme.swap, yDomain: 0...yMax,
                rangeSamples: model.range.sampleCount, height: 40,
                rules: [
                    .init(value: settings.swapDangerGB, color: Theme.danger),
                    .init(value: settings.swapCautionGB, color: Theme.warn),
                ],
                label: "최근 \(model.range.label) 스왑 사용량 그래프"
            )
        }
    }
}

private struct TopAppsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let _ = model.tick
        let dots = model.rowDots
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("상위 앱")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text2.color)
                Spacer()
                SegmentedToggle(
                    options: [(AppSort.memory, "메모리"), (.cpu, "CPU")],
                    selection: $model.sort, verticalPadding: 3
                )
            }
            .padding(.bottom, 4)
            ForEach(model.topApps) { group in
                AppRowView(group: group, dot: dots[group.id] ?? .ok, sort: model.sort)
            }
        }
    }
}

private struct FooterBar: View {
    var body: some View {
        HStack {
            Text("측정 1초 · 앱 목록 3초")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3.color)
            Spacer()
            Button {
                // 다음 단계: 설정 창
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text2.color)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("설정")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("앱 종료")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2.color)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line.color).frame(height: 1)
        }
    }
}
