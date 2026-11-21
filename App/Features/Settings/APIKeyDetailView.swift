import SwiftUI
import ScriberShared

/// Result of a key check, shared by the settings page and onboarding.
enum KeyCheck: Equatable {
    case idle
    case checking
    case valid
    case invalid(String)
}

/// Add, test, replace or delete one API key. A stored key is never shown back, only whether one exists.
struct APIKeyDetailView: View {
    let kind: APIKeyKind
    /// Put the cursor in the field right away (opened from a "設定 key" button).
    var focusOnAppear = false

    @Environment(SettingsModel.self) private var settings
    @State private var draft = ""
    @State private var check: KeyCheck = .idle
    @State private var confirmDelete = false
    @FocusState private var fieldFocused: Bool

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasKey: Bool { settings.hasKey(kind) }

    var body: some View {
        Form {
            Section {
                SecureField(hasKey ? "貼上新的 key 來取代" : "貼上 API key", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
            } header: {
                HStack {
                    SectionTitle("API key", info: "key 只存在這支手機的鑰匙圈裡，Scriber 直接用它連到服務商，不會傳給開發者。費用由服務商向你收取。")
                    Spacer()
                    StatusBadge(isOn: hasKey)
                        .font(.footnote)
                        .textCase(nil)
                }
            }

            Section {
                Button(action: save) {
                    Text("儲存")
                        .fontWeight(.semibold)
                }
                .disabled(trimmedDraft.isEmpty)
                Button(action: test) {
                    HStack {
                        Text(trimmedDraft.isEmpty ? "測試目前的 key" : "測試這組 key")
                        Spacer()
                        KeyCheckIndicator(check: check)
                    }
                }
                .disabled(check == .checking || (trimmedDraft.isEmpty && !hasKey))
            } footer: {
                KeyCheckMessage(check: check)
            }

            if let url = kind.consoleURL {
                Section {
                    Link(destination: url) {
                        HStack {
                            Text("到 \(kind.vendor) 取得 API key")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if hasKey {
                Section {
                    Button("刪除 API key", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(kind.vendor)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if focusOnAppear, !hasKey { fieldFocused = true }
        }
        .confirmationDialog("要刪除 \(kind.vendor) 的 API key 嗎？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                settings.deleteKey(kind)
                check = .idle
                Haptics.tap()
            }
        } message: {
            Text("用到這組 key 的功能會停止運作。")
        }
    }

    private func save() {
        let value = trimmedDraft
        guard !value.isEmpty else { return }
        settings.saveKey(value, for: kind)
        settings.adoptEngineIfNeeded(afterSaving: kind)
        draft = ""
        fieldFocused = false
        Haptics.success()
        // Check the key that was just saved so the user knows right away.
        runCheck(draft: value)
    }

    private func test() {
        fieldFocused = false
        runCheck(draft: trimmedDraft.isEmpty ? nil : trimmedDraft)
    }

    private func runCheck(draft: String?) {
        check = .checking
        Task {
            let message = await settings.validate(kind, draft: draft)
            check = message.map(KeyCheck.invalid) ?? .valid
            if message == nil { Haptics.success() } else { Haptics.error() }
        }
    }
}

/// Trailing spinner / check / cross for a key test.
struct KeyCheckIndicator: View {
    let check: KeyCheck

    var body: some View {
        switch check {
        case .idle: EmptyView()
        case .checking: ProgressView()
        case .valid: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// Section footer text for a key test.
struct KeyCheckMessage: View {
    let check: KeyCheck

    var body: some View {
        switch check {
        case .idle: EmptyView()
        case .checking: Text("正在確認…")
        case .valid: Text("可以使用。").foregroundStyle(.green)
        case .invalid(let message): Text(message).foregroundStyle(.red)
        }
    }
}
