import SwiftUI
import ScriberCore
import ScriberShared

/// One mode (設定 → 模式 → a mode), every change saved right away. Sections follow
/// docs/PRD-模式.md §2 minus what iOS cannot do: 基本, 辨識, 文字格式, AI 處理, 輸出. No hotkeys,
/// auto-apply, context, answer panel, auto-send, real-time text or model: those are Mac-only.
/// "跟隨預設" items name the value they follow (設定頁).
struct ModeEditorView: View {
    let modeID: String

    @Environment(ModeStore.self) private var store
    @Environment(PromptLibrary.self) private var library
    @Environment(SettingsModel.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var confirmDelete = false
    @State private var confirmRestore = false
    @FocusState private var nameFocused: Bool

    private var mode: DictationModeConfig? { store.modes.first { $0.id == modeID } }
    private var info: ModeInfo { ModeInfo(settings: settings, modes: store.modes, prompts: library.prompts) }
    private var enabledCount: Int { store.modes.filter(\.isEnabled).count }

    var body: some View {
        Group {
            if let mode {
                form(mode)
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .navigationTitle(mode?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let mode {
                ToolbarItem(placement: .topBarTrailing) { moreMenu(mode) }
            }
        }
        .onAppear { name = mode?.name ?? "" }
        .onChange(of: mode?.name) { _, newValue in
            if !nameFocused, let newValue, newValue != name { name = newValue }
        }
        .confirmationDialog("刪除「\(mode?.name ?? "")」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                do {
                    try store.delete(id: modeID)
                    DiagLog.log("modes", "mode deleted id=\(modeID)")
                } catch {
                    DiagLog.log("modes", "mode delete refused id=\(modeID) \(error)")
                }
            }
        } message: {
            Text("這個動作無法復原。")
        }
        .confirmationDialog("還原成出廠設定？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("還原") {
                try? store.restoreDefault(id: modeID)
                name = store.mode(id: modeID)?.name ?? name
                DiagLog.log("modes", "mode restored id=\(modeID)")
            }
        } message: {
            Text("名稱、圖示和其他設定都會還原。")
        }
    }

    private func form(_ mode: DictationModeConfig) -> some View {
        let info = info
        let resolved = info.resolved(mode)
        let template = info.prompt(mode)
        return ScrollViewReader { proxy in
            Form {
                basicSection(mode)
                recognitionSection(mode, resolved: resolved, info: info)
                formatSection(mode, resolved: resolved)
                aiSection(mode, resolved: resolved, template: template, info: info)
                outputSection(mode, template: template, info: info)
                    .id("output")
            }
            .task {
                // DEBUG layout review only: `-ScriberScrollTo output`.
                guard let target = DebugLaunch.scrollTarget else { return }
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    // MARK: Toolbar

    private func moreMenu(_ mode: DictationModeConfig) -> some View {
        Menu {
            if info.defaultModeID != mode.id {
                Button {
                    ModeActions.setDefault(mode.id, store: store)
                } label: {
                    Label("設為預設", systemImage: "checkmark.circle")
                }
            }
            Button {
                duplicate(mode)
            } label: {
                Label("複製成新模式", systemImage: "plus.square.on.square")
            }
            Divider()
            if mode.isBuiltIn {
                Button {
                    confirmRestore = true
                } label: {
                    Label("還原預設…", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("刪除…", systemImage: "trash")
                }
                .disabled(mode.isEnabled && enabledCount <= 1)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
    }

    // MARK: 基本

    private func basicSection(_ mode: DictationModeConfig) -> some View {
        Section {
            TextField("名稱", text: $name)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { commitName() }
                .onChange(of: name) { _, value in
                    if value.count > ModeInfo.maxNameLength { name = String(value.prefix(ModeInfo.maxNameLength)) }
                    commitName(keepEmpty: true)
                }
                .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            NavigationLink {
                ModeIconPicker(selection: Binding(get: { mode.icon }, set: { icon in update { $0.icon = icon } }))
            } label: {
                LabeledContent("圖示") {
                    Image(systemName: mode.icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            Toggle(isOn: Binding(get: { mode.isEnabled }, set: { enabled in update { $0.isEnabled = enabled } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("啟用")
                    if mode.isEnabled && enabledCount <= 1 {
                        Text("至少要有一個模式是開著的")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(mode.isEnabled && enabledCount <= 1)
        } header: {
            Text(mode.isBuiltIn ? "內建模式" : "自訂模式")
        }
    }

    /// Saves the typed name (trimmed). An empty field is kept while typing and put back on leaving.
    private func commitName(keepEmpty: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mode else { return }
        if trimmed.isEmpty {
            if !keepEmpty { name = mode.name }
            return
        }
        guard trimmed != mode.name else { return }
        update { $0.name = trimmed }
    }

    // MARK: 辨識

    private func recognitionSection(_ mode: DictationModeConfig, resolved: ResolvedModeConfig, info: ModeInfo) -> some View {
        let defaults = info.defaults
        let engines = STTProviderKind.builtIn + (settings.isCustomEngineConfigured || mode.recognition.engine == .custom(.custom)
            ? [.custom] : [])
        let engineReady = settings.isReady(resolved.sttProvider)
        return Section {
            Picker(selection: binding(\.recognition.engine)) {
                Text("跟隨預設（\(ModeInfo.engineName(defaults.sttProvider, settings: settings, short: true))）")
                    .tag(ModeOverride<STTProviderKind>.followDefault)
                ForEach(engines) { kind in
                    Text(ModeInfo.engineName(kind, settings: settings)).tag(ModeOverride<STTProviderKind>.custom(kind))
                }
            } label: {
                RowLabel("引擎", caption: engineReady ? nil : String(localized: "需要 \(resolved.sttProvider.requiredKey.vendor) 的 API key"),
                         isProblem: !engineReady)
            }
            Picker("語言", selection: binding(\.recognition.language)) {
                Text("跟隨預設（\(ModeInfo.languageName(defaults.languageCode))）").tag(ModeOverride<String>.followDefault)
                ForEach(languageChoices(mode), id: \.self) { code in
                    Text(ModeInfo.languageName(code)).tag(ModeOverride<String>.custom(code))
                }
            }
        } header: {
            SectionTitle("辨識", info: "「跟隨預設」用設定頁選的引擎。語言是給引擎的提示，中英夾雜選中文就好。")
        }
    }

    private func languageChoices(_ mode: DictationModeConfig) -> [String] {
        var codes = ModeInfo.languageCodes
        if let custom = mode.recognition.language.customValue, !codes.contains(custom) { codes.append(custom) }
        return codes
    }

    // MARK: 文字格式

    private func formatSection(_ mode: DictationModeConfig, resolved: ResolvedModeConfig) -> some View {
        let format = mode.textFormat
        let isCustom = !(format.forceTraditional.followsDefault && format.spaceBetweenCJKAndLatin.followsDefault
            && format.punctuationRule.followsDefault && format.punctuationLimit.followsDefault)
        return Section {
            Picker("格式", selection: Binding(get: { isCustom }, set: { custom in
                update { mode in
                    if custom {
                        mode.textFormat = ModeTextFormat(forceTraditional: .custom(resolved.forceTraditional),
                                                         spaceBetweenCJKAndLatin: .custom(resolved.spaceBetweenCJKAndLatin),
                                                         punctuationRule: .custom(resolved.punctuationRule),
                                                         punctuationLimit: .custom(resolved.punctuationLimit))
                    } else {
                        mode.textFormat = ModeTextFormat()
                    }
                }
            })) {
                Text("跟隨預設").tag(false)
                Text("自訂").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparator(isCustom ? .visible : .hidden, edges: .bottom)

            if isCustom {
                Toggle("一律輸出繁體中文", isOn: Binding(get: { resolved.forceTraditional },
                                                  set: { value in update { $0.textFormat.forceTraditional = .custom(value) } }))
                Toggle("中英文之間加空格", isOn: Binding(get: { resolved.spaceBetweenCJKAndLatin },
                                                  set: { value in update { $0.textFormat.spaceBetweenCJKAndLatin = .custom(value) } }))
                Picker("標點", selection: Binding(get: { resolved.punctuationRule },
                                                set: { value in update { $0.textFormat.punctuationRule = .custom(value) } })) {
                    ForEach(PunctuationRule.allCases) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }
                if resolved.punctuationRule != .keep {
                    Picker("套用範圍", selection: Binding(get: { resolved.punctuationLimit },
                                                      set: { value in update { $0.textFormat.punctuationLimit = .custom(value) } })) {
                        ForEach(limitChoices(resolved.punctuationLimit), id: \.self) { limit in
                            Text(PunctuationRule.limitName(limit)).tag(limit)
                        }
                    }
                }
            }
        } header: {
            SectionTitle("文字格式", info: "繁體、中英文空格和標點。「跟隨預設」用設定頁的輸出和標點符號設定。")
        }
    }

    private func limitChoices(_ current: Int) -> [Int] {
        AppSettings.punctuationLimitChoices.contains(current) ? AppSettings.punctuationLimitChoices
            : AppSettings.punctuationLimitChoices + [current]
    }

    // MARK: AI 處理

    private func aiSection(_ mode: DictationModeConfig, resolved: ResolvedModeConfig, template: PromptTemplate,
                           info: ModeInfo) -> some View {
        let defaults = info.defaults
        let needsAI = template.kind != .dictation
        let globalAI = defaults.polishProvider == .off ? String(localized: "關") : defaults.polishProvider.displayName
        return Section {
            if !needsAI {
                Picker(selection: binding(\.ai.enabled)) {
                    Text("跟隨預設（\(globalAI)）").tag(ModeOverride<Bool>.followDefault)
                    Text("開").tag(ModeOverride<Bool>.custom(true))
                    Text("關").tag(ModeOverride<Bool>.custom(false))
                } label: {
                    Text("AI 整理")
                }
            }
            if let llm = resolved.llm {
                providerPicker(mode, llm: llm, info: info)
                NavigationLink {
                    PromptPickerView(modeID: mode.id)
                } label: {
                    LabeledContent {
                        Text(template.name)
                    } label: {
                        // What the prompt does, unless its name already says it (翻譯, 助理…).
                        let kind = ModeInfo.promptKindName(template.kind)
                        RowLabel("提示詞", caption: kind == template.name ? nil : kind)
                    }
                }
                if template.kind == .translate {
                    Picker("翻譯成", selection: binding(\.ai.translateLanguageID)) {
                        Text("跟隨預設（\(TranslateLanguage.find(settings.translateLanguageID).displayName)）")
                            .tag(ModeOverride<String>.followDefault)
                        ForEach(TranslateLanguage.all) { language in
                            Text(language.displayName).tag(ModeOverride<String>.custom(language.id))
                        }
                    }
                }
            }
        } header: {
            SectionTitle("AI 處理") {
                InfoText("用 AI 去掉口誤、整理標點和段落，或依提示詞改寫、翻譯。")
                InfoText("「跟隨預設」用設定頁的 AI 潤飾。翻譯、改寫這類提示詞一定會用 AI。")
                InfoText("翻譯「跟隨預設」時，可以在鍵盤長按模式鍵直接選語言。")
            }
        }
    }

    private func providerPicker(_ mode: DictationModeConfig, llm: ResolvedLLM, info: ModeInfo) -> some View {
        var followed = mode
        followed.ai.provider = .followDefault
        let followName = info.resolved(followed).llm.map(info.providerName) ?? PolishProviderKind.groq.displayName
        let missing = info.llmKeyMissing(llm)
        let chosen = mode.ai.provider.customValue.flatMap { $0 == .off ? nil : $0 }
        let fallback = chosen.flatMap { kind -> String? in
            guard let key = kind.requiredKey, !settings.hasKey(key), !missing else { return nil }
            return String(localized: "沒有 \(kind.displayName) 的 key，改用 \(info.providerName(llm))")
        }
        return Picker(selection: binding(\.ai.provider)) {
            Text("跟隨預設（\(followName)）").tag(ModeOverride<PolishProviderKind>.followDefault)
            ForEach([PolishProviderKind.groq, .anthropic], id: \.self) { kind in
                Text(kind.displayName).tag(ModeOverride<PolishProviderKind>.custom(kind))
            }
        } label: {
            RowLabel("服務", caption: missing ? String(localized: "需要 Groq 或 Anthropic 的 API key") : fallback,
                     isProblem: missing || fallback != nil)
        }
    }

    // MARK: 輸出

    private enum OutputChoice: Hashable { case paste, copyOnly }

    private func outputSection(_ mode: DictationModeConfig, template: PromptTemplate, info: ModeInfo) -> some View {
        let isDefault = info.defaultModeID == mode.id
        // iOS types an answer at the cursor: 「回答」 shows as 打到游標處 (and stays stored for the Mac).
        let choice: OutputChoice = mode.output == .copyOnly ? .copyOnly : .paste
        return Section {
            Picker("結果", selection: Binding(get: { choice }, set: { value in
                guard value != choice else { return }
                update { mode in
                    switch value {
                    case .paste: mode.output = template.kind == .rewrite ? .replaceSelection : .paste
                    case .copyOnly: mode.output = .copyOnly
                    }
                }
            })) {
                Text(template.kind == .rewrite ? "取代選取的文字" : "打到游標處").tag(OutputChoice.paste)
                Text("只複製").tag(OutputChoice.copyOnly)
            }
            LabeledContent("預設模式") {
                if isDefault {
                    Text("是").foregroundStyle(.secondary)
                } else {
                    Button("設為預設") { ModeActions.setDefault(mode.id, store: store) }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            SectionTitle("輸出") {
                InfoItem(title: String(localized: "打到游標處"),
                         text: String(localized: "打進你正在打字的地方。回答問題的模式（例如助理）也是把回答打進去。"))
                InfoItem(title: String(localized: "只複製"), text: String(localized: "放進剪貼簿，不打字，鍵盤會顯示「已複製」。"))
                InfoItem(title: String(localized: "預設模式"),
                         text: String(localized: "鍵盤沒有切換過時用這個模式，App 裡的麥克風也用它。設為預設時，鍵盤也會切過去。"))
            }
        }
    }

    // MARK: Saving

    private func binding<Value>(_ keyPath: WritableKeyPath<DictationModeConfig, Value>) -> Binding<Value> {
        Binding(
            get: { (mode ?? DictationModeConfig.builtIn(.dictate))[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ change: (inout DictationModeConfig) -> Void) {
        guard var updated = mode else { return }
        change(&updated)
        guard updated != mode else { return }
        do {
            try store.update(updated)
        } catch {
            DiagLog.log("modes", "mode update refused id=\(modeID) \(error)")
        }
    }

    private func duplicate(_ mode: DictationModeConfig) {
        guard var copy = try? store.duplicate(id: mode.id) else { return }
        copy.name = String("\(mode.name) 副本".prefix(ModeInfo.maxNameLength))
        copy.trigger.hotkey = nil
        try? store.update(copy)
        DiagLog.log("modes", "mode duplicated from=\(mode.id) id=\(copy.id)")
        Haptics.tap()
    }
}

/// A row title with an optional one-line caption under it (orange for a problem).
struct RowLabel: View {
    let title: LocalizedStringKey
    var caption: String?
    var isProblem = false

    init(_ title: LocalizedStringKey, caption: String? = nil, isProblem: Bool = false) {
        self.title = title
        self.caption = caption
        self.isProblem = isProblem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
    }
}
