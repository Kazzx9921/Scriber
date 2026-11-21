import SwiftUI
import ScriberShared

/// Name, OpenAI-compatible base URL, model id and key for `STTProviderKind.custom`.
/// Saving also selects the custom engine. The key is never shown back, only whether one exists.
struct CustomEngineView: View {
    @Environment(SettingsModel.self) private var settings
    /// Closes the sheet (when it is the sheet's root) or pops the page.
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var baseURL: String
    @State private var model: String
    @State private var keyDraft = ""
    @State private var showProblems = false
    @State private var check: KeyCheck = .idle
    @State private var confirmRemove = false
    @FocusState private var focus: Field?

    private enum Field { case name, url, model, key }

    init() {
        let store = AppSettings.shared
        _name = State(initialValue: store.customSTTName)
        _baseURL = State(initialValue: store.customSTTBaseURL)
        _model = State(initialValue: store.customSTTModel)
    }

    private var trimmedKey: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasStoredKey: Bool { settings.hasKey(.custom) }
    private var connectionProblem: String? { CustomEngineForm.problem(baseURL: baseURL, model: model) }
    private var keyProblem: String? {
        trimmedKey.isEmpty && !hasStoredKey ? String(localized: "請貼上 API key") : nil
    }
    private var canTrySave: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                FieldRow(title: "名稱") {
                    TextField("例如：OpenAI", text: $name)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .url }
                }
            }

            Section {
                FieldRow(title: "網址") {
                    TextField(text: $baseURL, prompt: Text(verbatim: "https://api.openai.com/v1")) { Text("網址") }
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { focus = .model }
                }
                FieldRow(title: "模型") {
                    TextField(text: $model, prompt: Text(verbatim: "whisper-1")) { Text("模型") }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .model)
                        .submitLabel(.next)
                        .onSubmit { focus = .key }
                }
            } header: {
                SectionTitle("連線", info: "任何 OpenAI 相容的語音轉文字服務都可以。網址填到 /v1 為止，Scriber 會在後面接上 /audio/transcriptions。")
            } footer: {
                if showProblems, let connectionProblem { ProblemText(connectionProblem) }
            }

            Section {
                SecureField(hasStoredKey ? "貼上新的 key 來取代" : "貼上 API key", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .key)
                    .submitLabel(.done)
                    .onSubmit(save)
            } header: {
                HStack {
                    Text("API key")
                    Spacer()
                    StatusBadge(isOn: hasStoredKey).font(.footnote)
                }
                .textCase(nil)
            } footer: {
                if showProblems, connectionProblem == nil, let keyProblem { ProblemText(keyProblem) }
            }

            Section {
                Button(action: test) {
                    HStack {
                        Text("測試連線")
                        Spacer()
                        KeyCheckIndicator(check: check)
                    }
                }
                .disabled(check == .checking || connectionProblem != nil || keyProblem != nil)
            } footer: {
                KeyCheckMessage(check: check)
            }

            if settings.isCustomEngineConfigured || hasStoredKey {
                Section {
                    Button("移除自訂引擎", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .navigationTitle("自訂引擎")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存", action: save)
                    .fontWeight(.semibold)
                    .disabled(!canTrySave)
            }
        }
        .onAppear {
            if baseURL.isEmpty { focus = .name }
        }
        .onChange(of: baseURL) { _, _ in check = .idle }
        .onChange(of: keyDraft) { _, _ in check = .idle }
        .confirmationDialog("要移除自訂引擎嗎？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                settings.removeCustomEngine()
                Haptics.tap()
                dismiss()
            }
        } message: {
            Text("網址、模型和 key 都會刪掉。")
        }
    }

    /// Checks the URL and key as typed, before saving.
    private func test() {
        focus = nil
        check = .checking
        let draft = trimmedKey.isEmpty ? nil : trimmedKey
        let url = baseURL
        Task {
            let message = await settings.validateCustom(draft: draft, baseURL: url)
            check = message.map(KeyCheck.invalid) ?? .valid
            if message == nil { Haptics.success() } else { Haptics.error() }
        }
    }

    private func save() {
        guard connectionProblem == nil, keyProblem == nil else {
            withAnimation(.snappy) { showProblems = true }
            Haptics.warning()
            return
        }
        settings.saveCustomEngine(name: name, baseURL: baseURL, model: model)
        if !trimmedKey.isEmpty { settings.saveKey(trimmedKey, for: .custom) }
        settings.sttProvider = .custom
        keyDraft = ""
        Haptics.success()
        dismiss()
    }
}

/// A caption above a text field inside a form row.
private struct FieldRow<Field: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            field
        }
        .padding(.vertical, 2)
    }
}

private struct ProblemText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
    }
}
