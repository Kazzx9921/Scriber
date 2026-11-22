import SwiftUI
import ScriberCore
import ScriberShared

struct SettingsView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(SetupStatus.self) private var setup
    @Environment(ModeStore.self) private var modeStore
    @Environment(PromptLibrary.self) private var promptLibrary

    @State private var keySheet: APIKeySheetItem?
    @State private var confirmRestartOnboarding = false
    @State private var debugAPIKey = DebugLaunch.screen == "apiKey"
    @State private var debugKeyboard = DebugLaunch.screen == "keyboardSetup"
    @State private var debugExperimental = DebugLaunch.screen == "experimental"
    @State private var debugModes = ["modes", "mode", "modeIcon", "modePrompt", "prompts"].contains(DebugLaunch.screen ?? "")
    @State private var debugPrompt: PromptEditorTarget?

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version)（\(build)）"
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                // MARK: Modes
                Section {
                    NavigationLink {
                        ModesView()
                    } label: {
                        LabeledContent("模式", value: String(localized: "\(modeStore.modes.filter(\.isEnabled).count) 個"))
                    }
                }

                speechSection
                polishSection
                translationSection

                // MARK: Output
                Section {
                    Toggle("一律輸出繁體中文", isOn: $settings.forceTraditional)
                    Toggle("中英文之間加空格", isOn: $settings.spaceBetweenCJKAndLatin)
                } header: {
                    SectionTitle("輸出") {
                        InfoText("中英文之間加空格：「我用 iPhone 打字」。不加：「我用iPhone打字」。")
                        InfoText("這裡是預設值，模式可以各自改。")
                    }
                }

                // MARK: Punctuation
                Section {
                    Picker("標點", selection: $settings.punctuationRule) {
                        ForEach(PunctuationRule.allCases) { rule in
                            Text(rule.displayName).tag(rule)
                        }
                    }
                    if settings.punctuationRule != .keep {
                        Picker("套用範圍", selection: $settings.punctuationLimit) {
                            ForEach(AppSettings.punctuationLimitChoices, id: \.self) { limit in
                                Text(PunctuationRule.limitName(limit)).tag(limit)
                            }
                        }
                    }
                } header: {
                    SectionTitle("標點符號") {
                        InfoText(LocalizedStringKey(PunctuationRule.explanation))
                        InfoText("這裡是預設值，模式可以各自改。")
                    }
                }

                // MARK: General
                Section {
                    Toggle("儲存歷史紀錄", isOn: $settings.saveHistory)
                    Toggle("觸覺回饋", isOn: $settings.hapticsEnabled)
                }

                // MARK: More
                Section {
                    NavigationLink {
                        KeyboardSetupView()
                    } label: {
                        LabeledContent("加入鍵盤") {
                            StatusBadge(isOn: setup.isKeyboardAdded, onText: "已加入", offText: "未加入")
                        }
                    }
                    NavigationLink {
                        APIKeysView()
                    } label: {
                        LabeledContent("API key", value: keyCountText)
                    }
                    NavigationLink("實驗功能") { ExperimentalSettingsView() }
                }

                // MARK: About
                Section {
                    LabeledContent("版本", value: versionText)
                    Link(destination: AppLinks.repository) {
                        HStack {
                            Label("GitHub 原始碼", systemImage: "chevron.left.forwardslash.chevron.right")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("重新進行首次設定") { confirmRestartOnboarding = true }
                } header: {
                    SectionTitle("關於", info: "Scriber 沒有自己的伺服器。聲音直接從手機送到你選的服務，不會傳任何資料給開發者。歷史紀錄和字典只存在這支手機。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .apiKeySheet(item: $keySheet)
            .navigationDestination(isPresented: $debugAPIKey) { APIKeyDetailView(kind: .groq) }
            .navigationDestination(isPresented: $debugKeyboard) { KeyboardSetupView() }
            .navigationDestination(isPresented: $debugExperimental) { ExperimentalSettingsView() }
            .navigationDestination(isPresented: $debugModes) { DebugModesScreen() }
            .sheet(item: $debugPrompt) { target in PromptEditorView(target: target, library: promptLibrary) }
            .task {
                switch DebugLaunch.screen {
                case "customEngine":
                    try? await Task.sleep(for: .milliseconds(500))
                    keySheet = APIKeySheetItem(kind: .custom)
                case "prompt", "promptNew":
                    try? await Task.sleep(for: .milliseconds(500))
                    debugPrompt = DebugLaunch.screen == "promptNew" ? PromptEditorTarget(promptID: nil)
                        : PromptEditorTarget(promptID: DebugLaunch.promptID ?? BuiltInPromptID.standard.rawValue)
                default:
                    break
                }
            }
            .confirmationDialog("要重新進行首次設定嗎？", isPresented: $confirmRestartOnboarding, titleVisibility: .visible) {
                Button("重新開始") { settings.hasCompletedOnboarding = false }
            } message: {
                Text("你的 key、字典和設定都會保留。")
            }
        }
    }

    // MARK: Speech engine

    private var speechSection: some View {
        Section {
            ForEach(STTProviderKind.builtIn) { kind in
                ProviderRow(title: kind.rowTitle, tag: kind.tag, isSelected: settings.sttProvider == kind,
                            onSelect: { select(kind) }) {
                    KeyStatusButton(isSet: settings.hasKey(kind.requiredKey)) { openKey(kind.requiredKey) }
                }
                if kind == .elevenLabsScribe, settings.sttProvider == .elevenLabsScribe {
                    RealtimeToggleRow()
                }
            }
            ProviderRow(title: settings.customEngineName,
                        tag: settings.isCustomEngineConfigured ? settings.customSTTModel : STTProviderKind.custom.tag,
                        isSelected: settings.sttProvider == .custom,
                        onSelect: { select(.custom) }) {
                KeyStatusButton(isSet: settings.isReady(.custom), setTitle: "設定") { openKey(.custom) }
            }
        } header: {
            SectionTitle("語音辨識引擎") {
                InfoText("把聲音轉成文字的服務，可以隨時切換。這是預設值，模式可以各自改。")
                ForEach(STTProviderKind.allCases) { kind in
                    InfoItem(title: kind == .custom ? String(localized: "自訂") : kind.displayName, text: kind.tradeoff)
                }
            }
        }
    }

    private func select(_ kind: STTProviderKind) {
        if kind == .custom, !settings.isCustomEngineConfigured {
            // Nothing to select yet: the form selects it when saved.
            openKey(.custom)
            return
        }
        if settings.sttProvider != kind {
            settings.sttProvider = kind
            Haptics.tap()
        }
        if !settings.isReady(kind) { openKey(kind.requiredKey) }
    }

    // MARK: Polish

    private var polishSection: some View {
        Section {
            ForEach(PolishProviderKind.allCases) { kind in
                ProviderRow(title: kind.displayName, tag: kind.tag, isSelected: settings.polishProvider == kind,
                            onSelect: { select(kind) }) {
                    if let key = kind.requiredKey {
                        KeyStatusButton(isSet: settings.hasKey(key)) { openKey(key) }
                    }
                }
            }
        } header: {
            SectionTitle("AI 潤飾") {
                InfoText("去掉口誤和贅字、改口只留最後的說法、整理標點和段落，不會改變你的意思。「聽寫」模式跟著這裡。翻譯、改寫和其他打開 AI 的模式不用開這個，只要有填 Groq 或 Anthropic 的 key 就能用。")
                ForEach(PolishProviderKind.allCases) { kind in
                    InfoItem(title: kind.displayName, text: kind.detail)
                }
            }
        }
    }

    private func select(_ kind: PolishProviderKind) {
        if settings.polishProvider != kind {
            settings.polishProvider = kind
            Haptics.tap()
        }
        if let key = kind.requiredKey, !settings.hasKey(key) { openKey(key) }
    }

    private func openKey(_ kind: APIKeyKind) {
        keySheet = APIKeySheetItem(kind: kind)
    }

    // MARK: Translation

    private var translationSection: some View {
        @Bindable var settings = settings

        return Section {
            Picker("翻譯成", selection: $settings.translateLanguageID) {
                ForEach(TranslateLanguage.all) { language in
                    Text(language.displayName).tag(language.id)
                }
            }
            ForEach(0..<3, id: \.self) { index in
                Picker("常用語言 \(index + 1)", selection: quickLanguage(at: index)) {
                    ForEach(TranslateLanguage.all) { language in
                        Text(language.displayName).tag(language.id)
                    }
                }
            }
        } header: {
            SectionTitle("翻譯", info: "「翻譯」模式翻成上面的語言。在鍵盤長按模式鍵，可以直接選三個常用語言。")
        }
    }

    private func quickLanguage(at index: Int) -> Binding<String> {
        Binding(
            get: {
                let ids = settings.translateQuickLanguageIDs
                return ids.indices.contains(index) ? ids[index] : ""
            },
            set: { settings.setQuickLanguage($0, at: index) }
        )
    }

    private var keyCountText: String {
        let count = APIKeyKind.allCases.filter { settings.hasKey($0) }.count
        return count == 0 ? String(localized: "未設定") : String(localized: "\(count) 組")
    }
}

/// 邊講邊辨識 under Scribe v3 (the only engine with a real-time model), placed like the Mac's
/// 即時顯示文字. On iOS nothing is shown while speaking: the text is just ready sooner.
private struct RealtimeToggleRow: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Toggle(isOn: $settings.realtimeEnabled) {
            HStack(spacing: 2) {
                Text("邊講邊辨識")
                InfoButton {
                    InfoText("說話時就先辨識，停止後更快出字。")
                    InfoText("只有 Scribe v3 支援。錄音時會一直上傳聲音，比較耗流量，計價也跟一般辨識略有不同。")
                }
            }
        }
        // Under the engine's name (checkmark column 18 pt + 12 pt spacing in `ProviderRow`).
        .padding(.leading, 30)
    }
}

#if DEBUG
/// `-ScriberScreen modes|mode|modeIcon|modePrompt|prompts`: opens the screen directly (layout review).
private struct DebugModesScreen: View {
    @Environment(ModeStore.self) private var store

    var body: some View {
        let id = DebugLaunch.modeID ?? BuiltInModeID.dictate.rawValue
        switch DebugLaunch.screen {
        case "mode": ModeEditorView(modeID: id)
        case "modePrompt": PromptPickerView(modeID: id)
        case "prompts": PromptLibraryView()
        case "modeIcon":
            ModeIconPicker(selection: Binding(get: { store.mode(id: id)?.icon ?? "mic" }, set: { _ in }))
        default: ModesView()
        }
    }
}
#else
private struct DebugModesScreen: View {
    var body: some View { EmptyView() }
}
#endif
