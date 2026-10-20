import SwiftUI

/// 아이콘 클릭 시 뜨는 팝오버 내용. 폭 380, 다크 고정.
struct PopoverView: View {
    let model: AppModel
    let openSettings: () -> Void

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
            FooterBar(openSettings: openSettings)
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
        guard let latest = model.latest, let cause = model.dangerCause else { return "메모리 위험" }
        return "메모리 위험 — " + Judgement.causeTitle(cause: cause, swapBytes: latest.swapUsedBytes, availablePercent: latest.availablePercent)
    }

    private var message: String {
        guard let cause = model.dangerCause else { return "" }
        let minutes = model.dangerSince.map { Judgement.dangerMinutes(since: $0, now: Date()) } ?? 1
        let top = model.topMemoryGroup.map { (name: $0.displayName, footprint: $0.footprint) }
        return Judgement.bannerBody(cause: cause, settings: model.settings, minutes: minutes, top: top)
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
    /// 접힌 행의 실제 높이(첫 측정 전 기본값). 목록 높이 = 접힌 행 5개.
    @State private var rowHeight: CGFloat = 46
    @State private var scroll = ScrollMetrics()

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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        ForEach(model.topApps) { group in
                            AppRowView(model: model, group: group, dot: dots[group.id] ?? .ok)
                                .id(group.id)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                    if model.expandedID != group.id { rowHeight = height }
                                }
                        }
                    }
                }
                .frame(height: rowHeight * 5 + Self.rowSpacing * 4)
                // 시스템 스크롤 막대는 폭을 차지해 행이 왼쪽으로 밀리므로 숨기고, 얇은 막대를 위에 겹쳐 그린다.
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                    ScrollMetrics(
                        content: geometry.contentSize.height,
                        container: geometry.containerSize.height,
                        offset: geometry.contentOffset.y
                    )
                } action: { _, metrics in scroll = metrics }
                .overlay(alignment: .topTrailing) { ThinScrollIndicator(metrics: scroll) }
                .onChange(of: model.expandedID) { _, id in
                    guard let id else { return }
                    // 펼친 내용이 레이아웃된 뒤, 보이도록 필요한 만큼만 스크롤
                    DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private static let rowSpacing: CGFloat = 4
}

private struct ScrollMetrics: Equatable {
    var content: CGFloat = 0
    var container: CGFloat = 0
    var offset: CGFloat = 0
}

/// 목록 위에 겹쳐 그리는 3pt 스크롤 막대. 스크롤할 내용이 있을 때만 보인다.
private struct ThinScrollIndicator: View {
    let metrics: ScrollMetrics
    private static let width: CGFloat = 3
    private static let minThumb: CGFloat = 20

    var body: some View {
        let scrollable = metrics.content - metrics.container
        if scrollable > 1, metrics.container > 0 {
            let thumb = max(Self.minThumb, metrics.container * metrics.container / metrics.content)
            let progress = min(1, max(0, metrics.offset / scrollable))
            Capsule()
                .fill(Theme.text3.opacity(0.6).color)
                .frame(width: Self.width, height: thumb)
                .offset(x: -1, y: (metrics.container - thumb) * progress)
                .allowsHitTesting(false)
        }
    }
}

private struct FooterBar: View {
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Text("측정 1초 · 앱 목록 3초")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3.color)
            Spacer()
            Button {
                openSettings()
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
