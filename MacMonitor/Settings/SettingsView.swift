import AppKit
import SwiftUI

/// 설정 창 내용 (시안 Settings). 값은 바꾸는 즉시 model.settings 에 반영된다.
struct SettingsView: View {
    @Bindable var model: AppModel

    private static let titlebarHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            GeneralSection()
            ThresholdSection(model: model)
            NotificationSection(model: model)
            CharacterSection()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        // fullSizeContentView 라 내용이 타이틀바 밑으로 들어간다. 타이틀바(28) 만큼 위 여백을 직접 둔다.
        .padding(.top, 20 + Self.titlebarHeight)
        .frame(width: 552)
        // 유리는 타이틀바·하단 안전 영역까지 창 전체를 덮는다.
        .background { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 0)).padding(.bottom, -60).ignoresSafeArea() }
        .ignoresSafeArea()
        .monospacedDigit()
        .preferredColorScheme(.dark)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            content
        }
    }
}

private extension View {
    /// 섹션 카드: 팝오버 모듈과 같은 맑은 유리, radius 18, 가로 padding 16
    func settingsCard() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(Theme.moduleGlass, in: .rect(cornerRadius: Theme.moduleRadius, style: .continuous))
    }
}

private struct GeneralSection: View {
    @State private var isOn = LoginItem.isOn
    @State private var message: String? = LoginItem.needsApproval ? Self.approvalMessage : nil

    private static let approvalMessage = "시스템 설정 > 일반 > 로그인 항목에서 허용해 주세요."

    var body: some View {
        SettingsSection(title: "일반") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("로그인 시 자동 실행")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Spacer()
                    Toggle("로그인 시 자동 실행", isOn: binding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .frame(height: 40)
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .padding(.bottom, 8)
                }
            }
            .settingsCard()
        }
    }

    /// 토글하면 register/unregister 하고, 실패하면 스위치를 되돌리고 에러 한 줄을 보인다.
    private var binding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                    isOn = LoginItem.isOn
                    message = LoginItem.needsApproval ? Self.approvalMessage : nil
                } catch {
                    isOn = LoginItem.isOn
                    message = "자동 실행을 바꾸지 못했어요: \(error.localizedDescription)"
                }
            }
        )
    }
}

private struct ThresholdSection: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsSection(title: "위험 기준") {
            VStack(spacing: 0) {
                ThresholdRow(
                    label: "스왑 사용량", level: "주의", color: Theme.warn, hint: "앵무새가 노랑으로 바뀌어요",
                    value: $model.settings.swapCautionGB, unit: "GB", allowsDecimal: true,
                    validate: { SettingsValidation.swapCaution($0, danger: model.settings.swapDangerGB) })
                ThresholdRow(
                    label: "스왑 사용량", level: "위험", color: Theme.danger, hint: "앵무새가 코랄로 바뀌고 알림이 와요",
                    value: $model.settings.swapDangerGB, unit: "GB", allowsDecimal: true,
                    validate: { SettingsValidation.swapDanger($0, caution: model.settings.swapCautionGB) })
                ThresholdRow(
                    label: "사용 가능 메모리", level: "위험", color: Theme.danger, hint: "이 값보다 적으면 위험",
                    value: $model.settings.availableDangerPercent, unit: "%",
                    validate: SettingsValidation.availablePercent)
                ThresholdRow(
                    label: "앱 하나의 CPU", level: "주의", color: Theme.warn, hint: "코어 1개 = 100%",
                    value: $model.settings.appCPUCautionPercent, unit: "%")
                ThresholdRow(
                    label: "CPU 급증 지속 시간", level: "주의", color: Theme.warn, hint: "이만큼 계속되면 알림",
                    value: $model.settings.spikeSeconds, unit: "초", isLast: true)
            }
            .settingsCard()
        }
    }
}

/// 라벨 + 주의/위험 칩 + 힌트 + 숫자 입력(64px) + 단위
private struct ThresholdRow: View {
    let label: String
    let level: String
    let color: Color
    let hint: String
    @Binding var value: Double
    let unit: String
    var allowsDecimal = false
    var isLast = false
    /// 값이 저장할 수 없는 입력이면 안내 문구를 돌려준다.
    var validate: ((Double) -> String?)?

    @State private var text = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    StatusLabel(text: level, color: color, tinted: false)
                        .padding(.leading, 2)
                }
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 10)
                    .frame(width: 64, height: 28)
                    .background(Theme.insetFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(focused ? Theme.accent : Theme.inputBorder, lineWidth: 1))
                    .accessibilityLabel("\(label) \(level) 기준")
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
            }
        }
        .frame(minHeight: 44)
        .padding(.bottom, errorMessage == nil ? 0 : 20)
        .overlay(alignment: .bottomTrailing) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .padding(.bottom, 6)
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
        .onAppear { text = Format.number(value) }
        .onChange(of: text) { _, newText in
            let cleaned = NumberInput.sanitize(newText, allowsDecimal: allowsDecimal)
            if cleaned != newText { text = cleaned }
            guard let parsed = Double(cleaned), parsed.isFinite else {
                errorMessage = nil
                return
            }
            // 검증에 걸리면 저장하지 않고 이전 값을 유지한다.
            if let message = validate?(parsed) {
                errorMessage = message
                return
            }
            errorMessage = nil
            // 양수만 저장한다. 0 이면 마지막 값을 유지한다.
            if let parsed = NumberInput.positive(cleaned), parsed != value { value = parsed }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                text = Format.number(value)
                errorMessage = nil
            }
        }
    }
}

/// 위험 기준 입력 검증 (순수 함수). 문제가 있으면 입력칸 아래에 보일 안내 문구를, 저장해도 되면 nil 을 돌려준다.
enum SettingsValidation {
    static let swapOrderMessage = "주의는 위험보다 작아야 해요"
    static let percentRangeMessage = "1~99 사이로 입력해 주세요"

    /// 스왑 주의는 위험보다 작아야 한다.
    static func swapCaution(_ caution: Double, danger: Double) -> String? {
        caution >= danger ? swapOrderMessage : nil
    }

    static func swapDanger(_ danger: Double, caution: Double) -> String? {
        caution >= danger ? swapOrderMessage : nil
    }

    /// 사용 가능 메모리 %: 1~99 정수
    static func availablePercent(_ percent: Double) -> String? {
        (1...99).contains(percent) && percent == percent.rounded() ? nil : percentRangeMessage
    }
}

/// 숫자 입력 검증 (순수 함수)
enum NumberInput {
    /// 숫자(와 소수 허용 시 점 하나)만 남긴다.
    static func sanitize(_ text: String, allowsDecimal: Bool) -> String {
        var seenDot = false
        return String(text.filter { character in
            if character.isASCII, character.isNumber { return true }
            if allowsDecimal, character == ".", !seenDot {
                seenDot = true
                return true
            }
            return false
        })
    }

    /// 0 보다 큰 수일 때만 값을 돌려준다.
    static func positive(_ text: String) -> Double? {
        guard let value = Double(text), value > 0, value.isFinite else { return nil }
        return value
    }
}

private struct NotificationSection: View {
    @Bindable var model: AppModel

    private static let options: [(minutes: Int, label: String)] = [
        (5, "5분마다"), (10, "10분마다"), (30, "30분마다"), (0, "다시 안 함"),
    ]

    var body: some View {
        SettingsSection(title: "알림") {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("위험이 계속되면 다시 알림")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Text("정상으로 돌아오면 초기화돼요")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("위험이 계속되면 다시 알림", selection: $model.settings.repeatIntervalMinutes) {
                    ForEach(Self.options, id: \.minutes) { Text($0.label).tag($0.minutes) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .frame(minHeight: 44)
            .settingsCard()
        }
    }
}

private struct CharacterSection: View {
    var body: some View {
        SettingsSection(title: "캐릭터") {
            HStack(spacing: 10) {
                VStack(spacing: 6) {
                    ParrotPreview()
                    Text("파티 앵무새")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 84)
                .background(Theme.expandedRowFill, in: RoundedRectangle(cornerRadius: Theme.moduleRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.moduleRadius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
                ForEach(0..<2, id: \.self) { _ in
                    Text("추가 예정")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 84)
                        .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: Theme.moduleRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.moduleRadius, style: .continuous)
                                .strokeBorder(Theme.placeholderBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityHint("사용할 수 없음")
                }
            }
        }
    }
}

/// 설정 창 안의 움직이는 앵무새 미리보기 (24×24, 메뉴바와 같은 흰 테두리, 10프레임 / 1초)
private struct ParrotPreview: View {
    private static let frames: [NSImage] = PartyParrot.outlineSources().map {
        NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let frames = Self.frames
            if !frames.isEmpty {
                let index = Int(context.date.timeIntervalSinceReferenceDate * 10) % frames.count
                Image(nsImage: frames[index])
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
