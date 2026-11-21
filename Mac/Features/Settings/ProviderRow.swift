import SwiftUI
import ScriberCore
import ScriberShared

/// One choice in an engine list, laid out like a Wi-Fi network row: a checkmark on the selected
/// one, name and a few words, and the API key control on the right of the same row.
///
/// The whole row highlights on hover and selects on click. A missing key shows a quiet 「未設定」;
/// the 「設定 key」 button fades in on hover, on keyboard focus, and always for the selected
/// provider (which cannot work without it). VoiceOver gets 「設定 key」 as an action on the row.
/// Selecting a provider whose key is missing selects it and opens the key field right there.
struct ProviderRow: View {
    let title: String
    let tag: String
    let isSelected: Bool
    /// nil: the provider needs no key.
    let keyKind: APIKeyKind?
    /// Selects the provider; returns true if its key is missing (the key field then opens).
    let onSelect: () -> Bool

    @Environment(MacSettings.self) private var settings
    @Environment(\.forcedHover) private var forcedHover
    @State private var showKeyEntry = false
    @State private var hovering = false

    private var keyMissing: Bool { keyKind.map { !settings.hasKey($0) } ?? false }
    private var highlighted: Bool { hovering || forcedHover }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if onSelect() { showKeyEntry = true }
            } label: {
                ProviderLabel(title: title, tag: tag, isSelected: isSelected)
            }
            .buttonStyle(PressableRowStyle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityValue(keyMissing ? "沒有 API key" : "")
            .accessibilityActions {
                if keyKind != nil {
                    Button(keyMissing ? "設定 key" : "更換 key") { showKeyEntry = true }
                }
            }

            if let keyKind {
                KeyControl(kind: keyKind, showEntry: $showKeyEntry,
                           reveal: highlighted || (isSelected && keyMissing))
            }
        }
        .modifier(HoverRow(highlighted: highlighted))
        .onHover { hovering = $0 }
    }
}

/// Checkmark, name, a few words.
struct ProviderLabel: View {
    let title: String
    let tag: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accentText)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                Text(tag).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The soft highlight behind a hovered settings row.
struct HoverRow: ViewModifier {
    let highlighted: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(highlighted ? 0.05 : 0))
            )
            .padding(.horizontal, -6)
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

/// Right side of a provider row: a quiet 「未設定」 that turns into a 「設定 key」 button when the
/// row is hovered or focused (or needs it); a quiet 「已設定」 menu (測試 / 更換 / 移除) once the key
/// is stored. A test result replaces the label for a few seconds. The stored key itself is never
/// read into the UI.
struct KeyControl: View {
    let kind: APIKeyKind
    @Binding var showEntry: Bool
    /// Show the 「設定 key」 button (hover, or the selected provider needs it).
    var reveal = true

    @Environment(MacSettings.self) private var settings
    @State private var result: CheckResult?
    @State private var checking = false
    @FocusState private var buttonFocused: Bool

    struct CheckResult: Equatable {
        var ok: Bool
        var label: String
    }

    var body: some View {
        // A stack (not a Group) so the popover stays anchored while the button turns into the
        // 「已設定」 menu after saving, and the check result stays visible.
        HStack(spacing: 0) {
            if settings.hasKey(kind) {
                Menu {
                    Button("測試") { test() }
                    Button("更換 key…") { showEntry = true }
                    Divider()
                    Button("移除", role: .destructive) {
                        settings.deleteKey(kind)
                        result = nil
                    }
                } label: {
                    if checking {
                        Text("測試中…")
                    } else if let result {
                        Label(result.label, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    } else {
                        Label("已設定", systemImage: "key.fill")
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(result.map { $0.ok ? Color.green : Theme.accent } ?? .secondary)
                .tint(result.map { $0.ok ? Color.green : Theme.accent } ?? .secondary)
                .help("\(settings.vendor(kind)) 的 API key")
            } else {
                let visible = reveal || buttonFocused || showEntry
                ZStack(alignment: .trailing) {
                    Text("未設定")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .opacity(visible ? 0 : 1)
                        .accessibilityHidden(true)
                    Button("設定 key") { showEntry = true }
                        .buttonStyle(.bordered)
                        .focused($buttonFocused)
                        .opacity(visible ? 1 : 0)
                        .help("填入 \(settings.vendor(kind)) 的 API key")
                        .accessibilityLabel("設定 \(settings.vendor(kind)) 的 API key")
                }
                .animation(.easeOut(duration: 0.15), value: visible)
            }
        }
        .popover(isPresented: $showEntry, arrowEdge: .trailing) {
            KeyEntryView(kind: kind) { showEntry = false }
                .environment(settings)
        }
    }

    private func test() {
        checking = true
        result = nil
        Task {
            let problem = await settings.validate(kind)
            checking = false
            result = problem.map { CheckResult(ok: false, label: HUDFeedback.forFailure(message: $0, retryable: false).label) }
                ?? CheckResult(ok: true, label: "可以使用")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            result = nil
        }
    }
}

/// Paste a key, save, and it is checked right away. Used in the row popover and in sheets.
struct KeyEntryView: View {
    let kind: APIKeyKind
    var onDone: () -> Void

    @Environment(MacSettings.self) private var settings
    @State private var draft = ""
    @State private var state: EntryState = .idle
    @FocusState private var focused: Bool

    enum EntryState: Equatable {
        case idle, checking, ok
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text("\(settings.vendor(kind)) API key").font(.headline)
                InfoButton("key 存在這台 Mac 的鑰匙圈，只會送到 \(settings.vendor(kind))。用途：\(kind.usage)。")
            }
            SecureField("貼上 API key", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($focused)
                .onSubmit(save)
            HStack(spacing: 8) {
                switch state {
                case .idle:
                    if let url = kind.consoleURL {
                        Link("取得 key", destination: url).font(.callout)
                    }
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("測試中…").font(.callout).foregroundStyle(.secondary)
                case .ok:
                    Label("可以使用", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                case .failed(let message):
                    Label(HUDFeedback.forFailure(message: message, retryable: false).label,
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.accent)
                        .help(message)
                }
                Spacer()
                Button("取消", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("儲存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state == .checking)
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        settings.saveKey(value, for: kind)
        draft = ""
        state = .checking
        Task {
            let problem = await settings.validate(kind)
            if let problem {
                state = .failed(problem)
            } else {
                state = .ok
                try? await Task.sleep(nanoseconds: 700_000_000)
                onDone()
            }
        }
    }
}

/// The custom engine as one more row: selecting it (or 「設定」) opens its form. Same hover
/// treatment as the provider rows.
struct CustomEngineRow: View {
    @Environment(MacSettings.self) private var settings
    @Environment(\.forcedHover) private var forcedHover
    @State private var showForm = false
    @State private var hovering = false
    @FocusState private var buttonFocused: Bool

    private var highlighted: Bool { hovering || forcedHover }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if settings.isCustomEngineConfigured, settings.hasKey(.custom) {
                    settings.sttProvider = .custom
                } else {
                    showForm = true
                }
            } label: {
                ProviderLabel(title: settings.customEngineName,
                              tag: settings.isCustomEngineConfigured ? settings.customSTTModel : "OpenAI 相容",
                              isSelected: settings.sttProvider == .custom)
            }
            .buttonStyle(PressableRowStyle())
            .accessibilityAddTraits(settings.sttProvider == .custom ? .isSelected : [])
            .accessibilityActions {
                Button("編輯自訂引擎") { showForm = true }
            }

            if settings.isReady(.custom) {
                Button {
                    showForm = true
                } label: {
                    Label("已設定", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("編輯自訂引擎")
            } else {
                let visible = highlighted || buttonFocused || showForm
                ZStack(alignment: .trailing) {
                    Text("未設定")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .opacity(visible ? 0 : 1)
                        .accessibilityHidden(true)
                    Button("設定") { showForm = true }
                        .buttonStyle(.bordered)
                        .focused($buttonFocused)
                        .opacity(visible ? 1 : 0)
                        .accessibilityLabel("設定自訂引擎")
                }
                .animation(.easeOut(duration: 0.15), value: visible)
            }
        }
        .modifier(HoverRow(highlighted: highlighted))
        .onHover { hovering = $0 }
        .sheet(isPresented: $showForm) {
            CustomEngineForm { showForm = false }
                .environment(settings)
        }
    }
}

/// Name, OpenAI-compatible base URL (https), model and key for the custom engine.
struct CustomEngineForm: View {
    var onDone: () -> Void

    @Environment(MacSettings.self) private var settings
    @State private var name = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                Text("自訂引擎").font(.headline)
                InfoButton("任何 OpenAI 相容的 /audio/transcriptions 服務。網址要用 https，填到 /v1 為止。")
            }
            Form {
                TextField("名稱", text: $name, prompt: Text("例如 OpenAI"))
                TextField("網址", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
                TextField("模型", text: $model, prompt: Text("whisper-1"))
                SecureField("API key", text: $key, prompt: Text(settings.hasKey(.custom) ? "不改就留空" : "貼上 API key"))
            }
            .formStyle(.columns)
            if let problem {
                ProblemRow(symbol: "exclamationmark.triangle.fill", text: problem)
            }
            HStack {
                if settings.isCustomEngineConfigured {
                    Button("移除", role: .destructive) {
                        settings.removeCustomEngine()
                        onDone()
                    }
                }
                Spacer()
                Button("取消", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("儲存並使用", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            name = settings.customSTTName
            baseURL = settings.customSTTBaseURL
            model = settings.customSTTModel
        }
    }

    private func save() {
        do {
            _ = try CustomSTTEndpoint.parse(baseURL)
        } catch {
            problem = (error as? CustomSTTError) == .insecureURL ? "網址要用 https:// 開頭" : "網址格式不對"
            return
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "請填模型名稱"
            return
        }
        guard settings.hasKey(.custom) || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "請填 API key"
            return
        }
        settings.saveCustomEngine(name: name, baseURL: baseURL, model: model)
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { settings.saveKey(key, for: .custom) }
        settings.sttProvider = .custom
        onDone()
    }
}

/// A key editor as a sheet (from Home's "還差一步" and the first-run window).
struct KeyEntrySheet: View {
    let kind: APIKeyKind
    var onDone: () -> Void

    var body: some View {
        if kind == .custom {
            CustomEngineForm(onDone: onDone)
        } else {
            KeyEntryView(kind: kind, onDone: onDone)
                .frame(width: 340)
        }
    }
}

/// `.sheet(item:)` wrapper so the contract enum doesn't need `Identifiable`.
struct KeySheetItem: Identifiable {
    let kind: APIKeyKind
    var id: String { kind.rawValue }
}
