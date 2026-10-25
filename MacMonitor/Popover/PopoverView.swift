import SwiftUI

/// 아이콘 클릭 시 뜨는 팝오버 내용. 폭 380, 다크 고정. 배경은 루트에 건 Liquid Glass (투명 NSPanel 위).
struct PopoverView: View {
    let model: AppModel
    let openSettings: () -> Void

    var body: some View {
        // 제어 센터처럼: 바깥 판도, 모듈 하나하나도 맑은 유리 조각. 판 뒤엔 dim 층.
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                if model.memoryLevel == .danger {
                    DangerBanner(model: model)
                }
                SystemHeader(model: model)
                CPUSection(model: model)
                MemorySection(model: model)
                SwapSection(model: model)
                TopAppsSection(model: model)
                FooterBar(openSettings: openSettings)
            }
        }
        .padding(12)
        .frame(width: 380)
        .monospacedDigit()
        .glassEffect(Theme.popoverGlass, in: .rect(cornerRadius: Theme.popoverRadius, style: .continuous))
        .background(Theme.popoverDim, in: .rect(cornerRadius: Theme.popoverRadius, style: .continuous))
        .preferredColorScheme(.dark)
        // 포커스를 뺏지 않는 패널이라 앱이 늘 비활성이고, 비활성 창의 유리는 굴절·테두리 반사광 없이 탁하게 그려진다.
        // 제어 센터처럼 맑은 유리로 보이도록 활성 상태로 고정한다.
        .environment(\.controlActiveState, .key)
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
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.bannerFill, in: RoundedRectangle(cornerRadius: Theme.moduleRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct SystemHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack {
            Text("시스템")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            SegmentedToggle(
                options: [(TimeRange.oneMinute, "1분"), (.tenMinutes, "10분"), (.oneHour, "1시간")],
                selection: $model.range
            )
        }
        .padding(.horizontal, 6)
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

/// 큰 숫자 + 작은 % (CPU·메모리 모듈 2행)
private struct BigPercent: View {
    let value: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(String(format: "%.1f", value))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.primary)
            Text("%")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Format.percent(value))
    }
}

private struct CPUSection: View {
    let model: AppModel

    var body: some View {
        let _ = model.tick
        let snapshot = model.latest
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CPU")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isCPUCaution {
                    StatusLabel(text: "주의", color: Theme.warn)
                } else {
                    StatusLabel(text: "정상", color: Theme.ok, tinted: false)
                }
            }
            BigPercent(value: snapshot?.cpuBusy ?? 0)
            Text("시스템 \(Format.percent(snapshot?.cpuSystem ?? 0)) · 사용자 \(Format.percent(snapshot?.cpuUser ?? 0)) · 대기 \(Format.percent(snapshot?.cpuIdle ?? 0))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            MetricChart(
                points: model.chartPoints(.cpu), tint: model.isCPUCaution ? Theme.warn : nil, yDomain: 0...100,
                rangeSamples: model.range.sampleCount, height: 52,
                label: "최근 \(model.range.label) CPU 사용률 그래프"
            )
            .padding(.top, 8)
        }
        .glassModule(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
    }
}

private struct MemorySection: View {
    let model: AppModel

    private var status: (text: String, color: Color, tinted: Bool) {
        let pressure = Format.wholePercent(model.latest?.pressurePercent ?? 0)
        switch model.memoryLevel {
        case .normal: return ("압력 정상 \(pressure)", Theme.ok, false)
        case .caution: return ("압력 주의 \(pressure)", Theme.warn, true)
        case .danger: return ("압력 위험 \(pressure)", Theme.danger, true)
        }
    }

    private var graphTint: Color? {
        switch model.memoryLevel {
        case .normal: nil
        case .caution: Theme.warn
        case .danger: Theme.danger
        }
    }

    var body: some View {
        let _ = model.tick
        let snapshot = model.latest
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("메모리")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                StatusLabel(text: status.text, color: status.color, tinted: status.tinted)
            }
            BigPercent(value: snapshot?.memoryPercent ?? 0)
            HStack(alignment: .top, spacing: 8) {
                MemoryFigure(label: "앱 메모리", value: Format.gb(snapshot?.appMemoryBytes ?? 0))
                MemoryFigure(label: "와이어드", value: Format.gb(snapshot?.wiredBytes ?? 0))
                MemoryFigure(label: "압축됨", value: Format.gb(snapshot?.compressedBytes ?? 0))
            }
            MetricChart(
                points: model.chartPoints(.memory), tint: graphTint, yDomain: 0...100,
                rangeSamples: model.range.sampleCount, height: 44,
                label: "최근 \(model.range.label) 메모리 사용률 그래프"
            )
            .padding(.top, 8)
        }
        .glassModule(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
    }
}

private struct MemoryFigure: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
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
        let overCaution = Double(swapBytes) > settings.swapCautionBytes
        let tint: Color? = overDanger ? Theme.danger : (overCaution ? Theme.warn : nil)
        let points = model.chartPoints(.swapGB)
        let yMax = Judgement.swapYMaxGB(dangerGB: settings.swapDangerGB, observedMaxGB: points.map(\.y).max() ?? 0)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("스왑")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(Format.gb(swapBytes))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("주의 \(Format.thresholdGB(settings.swapCautionGB)) · \(Text(overDanger ? "위험 \(Format.thresholdGB(settings.swapDangerGB)) 초과" : "위험 \(Format.thresholdGB(settings.swapDangerGB))").foregroundStyle(overDanger ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary)).fontWeight(overDanger ? .semibold : .regular))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            MetricChart(
                points: points, tint: tint, yDomain: 0...yMax,
                rangeSamples: model.range.sampleCount, height: 30,
                rules: [
                    .init(value: settings.swapDangerGB, color: Theme.danger),
                    .init(value: settings.swapCautionGB, color: Theme.warn),
                ],
                label: "최근 \(model.range.label) 스왑 사용량 그래프"
            )
        }
        .glassModule(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
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
        let tags = model.rowTags
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("상위 앱")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                SegmentedToggle(
                    options: [(AppSort.memory, "메모리"), (.cpu, "CPU")],
                    selection: $model.sort, verticalPadding: 3
                )
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        ForEach(model.topApps) { group in
                            AppRowView(model: model, group: group, dot: dots[group.id] ?? .ok, rowTag: tags[group.id])
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
        .glassModule(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 8))
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
                .fill(Theme.scrollIndicator)
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
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("설정")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("앱 종료")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 6)
    }
}
