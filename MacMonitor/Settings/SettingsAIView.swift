import AppKit
import SwiftUI

/// "AI 판정" 섹션: 스위치 + (켜면) 엔진 선택·API 키
struct AIVerdictSection: View {
    @Bindable var model: AppModel

    private enum Check { case none, checking, connected, invalid, saveFailed }

    @State private var keyText = ""
    @State private var hasKey = false
    @State private var check = Check.none

    private var engineID: String { model.settings.aiVerdictEngineID }

    var body: some View {
        SettingsSection(title: "AI 판정") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("AI 판정")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                        Text("끄면 규칙 태그만 보여요")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("AI 판정", isOn: $model.settings.aiVerdictEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .frame(minHeight: 44)
                if model.settings.aiVerdictEnabled {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    engineRow
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    keyRow
                    if !hasKey || check == .invalid {
                        Text("키를 넣어야 동작해요")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warn)
                            .padding(.bottom, 10)
                    }
                }
            }
            .settingsCard()
        }
        .onAppear { refreshHasKey() }
        .onChange(of: engineID) { _, _ in
            keyText = ""
            check = .none
            refreshHasKey()
        }
    }

    private var engineRow: some View {
        HStack {
            Text("판정 엔진")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer()
            Picker("판정 엔진", selection: $model.settings.aiVerdictEngineID) {
                ForEach(VerdictEngines.all, id: \.id) { Text($0.displayName).tag($0.id) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .frame(minHeight: 44)
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API 키")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
                statusText
            }
            HStack(spacing: 6) {
                SecureField(hasKey ? "저장됨 — 바꾸려면 새 키 입력" : "API 키 붙여넣기", text: $keyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.insetFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.inputBorder, lineWidth: 1))
                    .onSubmit(saveKey)
                    .accessibilityLabel("API 키")
                Button(action: saveKey) {
                    Text("저장").font(.system(size: 12)).padding(.horizontal, 6).frame(height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || check == .checking)
                Button(action: deleteKey) {
                    Text("삭제").font(.system(size: 12)).padding(.horizontal, 6).frame(height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(!hasKey)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusText: some View {
        switch check {
        case .checking: Text("확인 중").font(.system(size: 11)).foregroundStyle(.secondary)
        case .connected: Text("연결됨").font(.system(size: 11)).foregroundStyle(Theme.ok)
        case .invalid: Text("키가 올바르지 않아요").font(.system(size: 11)).foregroundStyle(Theme.danger)
        case .saveFailed: Text("저장하지 못했어요").font(.system(size: 11)).foregroundStyle(Theme.danger)
        case .none: if hasKey { Text("저장됨").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private func refreshHasKey() {
        hasKey = !(model.keyStore.key(for: engineID) ?? "").isEmpty
    }

    private func saveKey() {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, check != .checking else { return }
        let id = engineID
        do {
            try model.keyStore.save(key, for: id)
        } catch {
            check = .saveFailed
            return
        }
        keyText = ""
        hasKey = true
        check = .checking
        guard let engine = VerdictEngines.engine(id: id) else { return }
        Task {
            let ok = await engine.validate(apiKey: key)
            guard id == engineID else { return }
            check = ok ? .connected : .invalid
        }
    }

    private func deleteKey() {
        try? model.keyStore.delete(for: engineID)
        keyText = ""
        check = .none
        refreshHasKey()
    }
}

/// "AI 판정 기록" 섹션: 이번 달 요약 + 최근 호출 목록
struct AuditLogSection: View {
    let model: AppModel

    private enum Filter { case all, failures }
    private static let limit = 50

    @State private var filter = Filter.all
    @State private var entries: [VerdictAuditEntry] = []
    @State private var summary = AuditMonthSummary(calls: 0, inputTokens: 0, estimatedCostUSD: 0, failures: 0)
    @State private var openID: UUID?
    @State private var confirmingClear = false

    private static let timeFormat = Date.FormatStyle().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute().second()

    var body: some View {
        SettingsSection(title: "AI 판정 기록") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(AuditFormat.summary(summary))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    SegmentedToggle(options: [(Filter.all, "전체"), (.failures, "실패만")], selection: $filter, verticalPadding: 3)
                }
                .padding(.vertical, 10)
                Rectangle().fill(Theme.divider).frame(height: 1)
                if entries.isEmpty {
                    Text(filter == .all ? "기록이 없어요" : "실패한 호출이 없어요")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    ForEach(entries) { entry in
                        AuditRow(entry: entry, open: openID == entry.id) {
                            openID = openID == entry.id ? nil : entry.id
                        }
                    }
                }
                Rectangle().fill(Theme.divider).frame(height: 1)
                HStack(spacing: 6) {
                    Button { confirmingClear = true } label: {
                        Text("기록 지우기").font(.system(size: 12)).padding(.horizontal, 6).frame(height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    Button(action: revealInFinder) {
                        Text("Finder에서 보기").font(.system(size: 12)).padding(.horizontal, 6).frame(height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    Spacer()
                }
                .padding(.vertical, 10)
            }
            .settingsCard()
        }
        .task { await reload() }
        .onChange(of: filter) { _, _ in Task { await reload() } }
        .confirmationDialog("AI 판정 기록을 모두 지울까요?", isPresented: $confirmingClear) {
            Button("지우기", role: .destructive) {
                Task {
                    await model.auditLog.clear()
                    await reload()
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("지운 기록은 되돌릴 수 없어요.")
        }
    }

    private func reload() async {
        let failuresOnly = filter == .failures
        let list = await model.auditLog.recent(limit: Self.limit, failuresOnly: failuresOnly)
        let month = await model.auditLog.monthSummary()
        guard failuresOnly == (filter == .failures) else { return }
        entries = list
        summary = month
        if let openID, !list.contains(where: { $0.id == openID }) { self.openID = nil }
    }

    private func revealInFinder() {
        let url = model.auditLog.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private struct AuditRow: View {
        let entry: VerdictAuditEntry
        let open: Bool
        let onToggle: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onToggle) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(entry.time.formatted(AuditLogSection.timeFormat)) · \(entry.engineID) · \(entry.groupName)")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(entry.result)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(entry.latencyMs)ms · \(AuditFormat.status(entry))")
                            .font(.system(size: 11))
                            .foregroundStyle(entry.isFailure ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary))
                            .fixedSize()
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "접기" : "요청과 응답 펼치기")
                if open {
                    if let error = entry.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger).textSelection(.enabled)
                    }
                    BodyBox(title: "요청", text: AuditFormat.pretty(entry.requestBody))
                    BodyBox(title: "응답", text: AuditFormat.pretty(entry.responseBody))
                }
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
    }

    /// 요청/응답 JSON: 모노스페이스, 선택 가능, 복사 버튼
    private struct BodyBox: View {
        let title: String
        let text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(Theme.insetFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
