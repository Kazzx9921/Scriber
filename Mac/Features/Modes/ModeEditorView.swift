import SwiftUI
import ScriberCore
import ScriberShared

/// One mode, edited in place (pushed inside 模式, like a transcript in 轉錄): back, icon, name and
/// a "…" menu on top, then the settings page's grouped rows in the order of docs/PRD-模式.md §2:
/// 基本, 觸發, 辨識, 文字格式, AI 處理, 輸出. Every change is saved right away.
///
/// "跟隨預設" items name the value they follow. Only what works in this version is shown: automatic
/// apps, context, the answer / copy-only outputs, auto-send and the model come later (M3) and have
/// no controls here.
struct ModeEditorView: View {
    let modeID: String
    let store: ModeStore
    let prompts: PromptLibrary
    let onBack: () -> Void
    /// Snapshots: start with the combination recorder listening.
    var startsRecording = false

    static let maxNameLength = 20

    @Environment(MacSettings.self) private var settings
    @Environment(EngineStatus.self) private var status
    @State private var name = ""
    @State private var showIcons = false
    @State private var editingPrompt: PromptEditorTarget?
    @State private var pendingCombination = false
    @State private var confirmDelete = false
    @State private var confirmRestore = false
    @FocusState private var nameFocused: Bool

    private var mode: DictationModeConfig? { store.modes.first { $0.id == modeID } }

    private var context: ModeContext {
        ModeContext(settings: settings, modes: store.modes, prompts: prompts.prompts,
                    accessibilityTrusted: status.accessibilityTrusted, hotkey: status.hotkey)
    }

    var body: some View {
        Group {
            if let mode {
                content(mode)
            } else {
                Color.clear.onAppear(perform: onBack)
            }
        }
        .onAppear {
            name = mode?.name ?? ""
            if startsRecording { pendingCombination = true }
        }
        .onChange(of: mode?.name) { _, newValue in
            if !nameFocused, let newValue, newValue != name { name = newValue }
        }
        .sheet(item: $editingPrompt) { target in
            PromptEditorView(target: target, library: prompts, modes: store)
        }
        .confirmationDialog("刪除「\(mode?.name ?? "")」？", isPresented: $confirmDelete) {
            Button("刪除", role: .destructive) {
                try? store.delete(id: modeID)
                DiagLog.log("modes", "mode deleted id=\(modeID)")
                onBack()
            }
        } message: {
            Text("這個動作無法復原。")
        }
        .confirmationDialog("把「\(mode?.name ?? "")」還原成出廠設定？", isPresented: $confirmRestore) {
            Button("還原") {
                try? store.restoreDefault(id: modeID)
                name = store.mode(id: modeID)?.name ?? name
                DiagLog.log("modes", "mode restored id=\(modeID)")
            }
        } message: {
            Text("名稱、圖示、快捷鍵和其他設定都會還原。")
        }
    }

    private func content(_ mode: DictationModeConfig) -> some View {
        let context = context
        let resolved = context.resolved(mode)
        let template = context.prompt(mode)
        return VStack(spacing: 0) {
            header(mode, context: context)
            Form {
                basicSection(mode, enabledCount: store.modes.filter(\.isEnabled).count)
                triggerSection(mode, context: context)
                recognitionSection(mode, resolved: resolved, context: context)
                formatSection(mode, resolved: resolved)
                aiSection(mode, resolved: resolved, template: template, context: context)
                outputSection(mode, template: template, context: context)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Header

    private func header(_ mode: DictationModeConfig, context: ModeContext) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .keyboardShortcut("[", modifiers: .command)
            .help("回到模式（⌘[）")
            .accessibilityLabel("回到模式")
            ModeIconBadge(symbol: mode.icon, enabled: mode.isEnabled, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(mode.name)
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                    if context.currentModeID == mode.id { DefaultModeBadge() }
                }
                Text(mode.isBuiltIn ? "內建模式" : "自訂模式")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Menu {
                if context.currentModeID != mode.id {
                    Button("設為預設") { settings.setCurrentMode(mode.id, store: store) }
                }
                Button("複製成新模式") { duplicate(mode) }
                Divider()
                if mode.isBuiltIn {
                    Button("還原預設…") { confirmRestore = true }
                } else {
                    Button("刪除…", role: .destructive) { confirmDelete = true }
                        .disabled(mode.isEnabled && store.modes.filter(\.isEnabled).count <= 1)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("更多")
        }
        .padding(.horizontal, 28)
        .padding(.top, MainLayout.topInset)
        .padding(.bottom, 6)
    }

    // MARK: 基本

    private func basicSection(_ mode: DictationModeConfig, enabledCount: Int) -> some View {
        Section {
            TextField("名稱", text: $name)
                .focused($nameFocused)
                .onSubmit { commitName() }
                .onChange(of: name) { _, value in
                    if value.count > Self.maxNameLength { name = String(value.prefix(Self.maxNameLength)) }
                    commitName(keepEmpty: true)
                }
                .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            LabeledContent("圖示") {
                Button {
                    showIcons.toggle()
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(width: 34, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.13)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("換一個圖示")
                .accessibilityLabel("圖示，按一下更換")
                .popover(isPresented: $showIcons, arrowEdge: .bottom) {
                    ModeIconGrid(selection: Binding(get: { mode.icon }, set: { icon in
                        update { $0.icon = icon }
                        showIcons = false
                    }))
                }
            }
            Toggle(isOn: Binding(get: { mode.isEnabled }, set: { enabled in
                update { $0.isEnabled = enabled }
                if !enabled, mode.id == BuiltInModeID.translate.rawValue, settings.translateLocked {
                    settings.translateLocked = false
                }
            })) {
                RowTitle("啟用", caption: mode.isEnabled && enabledCount <= 1 ? "至少要有一個模式是開著的" : nil)
            }
            .disabled(mode.isEnabled && enabledCount <= 1)
        } header: {
            Text("基本")
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

    // MARK: 觸發

    private enum HotkeyChoice: Hashable {
        case none
        case modifiers(Set<ModifierFamily>)
        case combination
    }

    private func triggerSection(_ mode: DictationModeConfig, context: ModeContext) -> some View {
        let shortcut = mode.trigger.hotkey.flatMap(ModeShortcut.init)
        let routes = context.routes
        let problem = context.problem(mode, routes: routes)
        let choice: HotkeyChoice = {
            // 自己的組合鍵 just chosen: the recorder is waiting, the old hotkey stays until a new one is pressed.
            if pendingCombination { return .combination }
            switch shortcut {
            case .withTrigger(let families)?: return .modifiers(families)
            case .combination?: return .combination
            case nil: return .none
            }
        }()
        let caption: String? = {
            if let problem { return problem.message }
            guard let shortcut else { return nil }
            if !mode.isEnabled { return "模式停用中" }
            return context.sentence(shortcut)
        }()
        let singleFamilies: [ModifierFamily] = [.shift, .control, .option, .command]
        return Section {
            Picker(selection: Binding(get: { choice }, set: { setHotkey($0, mode: mode) })) {
                Text("不使用").tag(HotkeyChoice.none)
                Divider()
                ForEach(singleFamilies, id: \.self) { family in
                    Text("按住 \(family.displayName) 再按快捷鍵").tag(HotkeyChoice.modifiers([family]))
                }
                if case .modifiers(let families) = choice, families.count > 1 {
                    Text("按住 \(KeyCombo.displayOrder.filter(families.contains).map(\.symbol).joined()) 再按快捷鍵")
                        .tag(choice)
                }
                Divider()
                Text("自己的組合鍵").tag(HotkeyChoice.combination)
            } label: {
                RowTitle("快捷鍵", caption: choice == .combination ? nil : caption,
                         captionIsProblem: choice != .combination && problem != nil)
            }
            .pickerStyle(.menu)
            if choice == .combination {
                comboRow(mode, shortcut: shortcut, problem: problem, context: context)
                    .padding(.leading, 26)
            }
        } header: {
            SectionHeader("觸發") {
                InfoItem(title: "按住修飾鍵再按快捷鍵", text: "例如按住 ⇧ 再按快捷鍵。有沒有開自動貼上都能用。")
                InfoItem(title: "自己的組合鍵", text: "例如 ⌃⌥M，或單獨一個 F 鍵。不需要任何權限，隨時可用。")
                InfoText("點一下或按住，跟主要快捷鍵的操作方式一樣。")
            }
        }
    }

    private func comboRow(_ mode: DictationModeConfig, shortcut: ModeShortcut?, problem: ModeHotkeyProblem?,
                          context: ModeContext) -> some View {
        var keys: [String] = []
        if !pendingCombination, case .combination(let combo)? = shortcut { keys = combo.keycaps }
        let recorder = ModeComboRecorder(
            keys: keys,
            validate: { combo in validate(combo, for: mode, context: context) },
            save: { combo in
                update { $0.trigger.hotkey = ModeShortcut.combination(combo).modeHotkey }
                pendingCombination = false
                DiagLog.log("modes", "mode hotkey id=\(mode.id) combo=\(combo.logDescription)")
            },
            onCancel: { pendingCombination = false })
        let note: RowNote? = {
            if keys.isEmpty { return nil }
            if let problem { return RowNote(text: problem.message, isProblem: true) }
            if !mode.isEnabled { return RowNote(text: "模式停用中", isProblem: false) }
            return nil
        }()
        return HotkeyRecorderRow(target: .modeCombination(recorder), title: "組合鍵", note: note,
                                 initialPhase: startsRecording ? .listening : .idle,
                                 autoStart: keys.isEmpty && !startsRecording)
    }

    /// Why `combo` cannot be this mode's combination (nil: it can).
    private func validate(_ combo: KeyCombo, for mode: DictationModeConfig, context: ModeContext) -> String? {
        var changed = mode
        changed.isEnabled = true
        changed.trigger.hotkey = ModeShortcut.combination(combo).modeHotkey
        let modes = store.modes.map { $0.id == mode.id ? changed : $0 }
        let routes = HotkeyRoutes.build(config: settings.hotkey,
                                        candidates: ModeHotkeyCandidate.list(modes: modes, prompts: prompts.prompts),
                                        accessibilityTrusted: status.accessibilityTrusted)
        return routes.problems[mode.id]?.message
    }

    private func setHotkey(_ choice: HotkeyChoice, mode: DictationModeConfig) {
        switch choice {
        case .none:
            pendingCombination = false
            update { $0.trigger.hotkey = nil }
        case .modifiers(let families):
            pendingCombination = false
            update { $0.trigger.hotkey = ModeShortcut.withTrigger(families).modeHotkey }
        case .combination:
            if case .combination? = mode.trigger.hotkey?.kind { return }
            // The recorder appears and listens; nothing is saved until a combination is pressed.
            pendingCombination = true
            return
        }
        DiagLog.log("modes", "mode hotkey id=\(mode.id) \(choice == .none ? "none" : "withTrigger")")
    }

    // MARK: 辨識

    private func recognitionSection(_ mode: DictationModeConfig, resolved: ResolvedModeConfig,
                                    context: ModeContext) -> some View {
        let defaults = context.defaults
        let engines = STTProviderKind.builtIn + (settings.isCustomEngineConfigured || mode.recognition.engine == .custom(.custom)
            ? [.custom] : [])
        let engineReady = settings.isReady(resolved.sttProvider)
        return Section {
            Picker(selection: binding(\.recognition.engine)) {
                Text("跟隨預設（\(ModeContext.engineName(defaults.sttProvider, settings: settings))）")
                    .tag(ModeOverride<STTProviderKind>.followDefault)
                Divider()
                ForEach(engines) { kind in
                    Text(ModeContext.engineName(kind, settings: settings)).tag(ModeOverride<STTProviderKind>.custom(kind))
                }
            } label: {
                RowTitle("引擎", caption: engineReady ? nil : "需要 \(settings.vendor(resolved.sttProvider.requiredKey)) 的 API key，到設定填入",
                         captionIsProblem: !engineReady)
            }
            .pickerStyle(.menu)

            Picker("語言", selection: binding(\.recognition.language)) {
                Text("跟隨預設（\(ModeContext.languageName(defaults.languageCode))）").tag(ModeOverride<String>.followDefault)
                Divider()
                ForEach(languageChoices(mode), id: \.self) { code in
                    Text(ModeContext.languageName(code)).tag(ModeOverride<String>.custom(code))
                }
            }
            .pickerStyle(.menu)

            if resolved.sttProvider == .elevenLabsScribe {
                Picker(selection: binding(\.recognition.realtime)) {
                    Text("跟隨預設（\(ModeContext.onOff(defaults.realtimeEnabled))）").tag(ModeOverride<Bool>.followDefault)
                    Divider()
                    Text("開").tag(ModeOverride<Bool>.custom(true))
                    Text("關").tag(ModeOverride<Bool>.custom(false))
                } label: {
                    HStack(spacing: 4) {
                        Text("即時顯示文字")
                        InfoButton("邊說邊顯示辨識出的文字。只有 Scribe v3 可以。")
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            SectionHeader("辨識", info: "「跟隨預設」用設定頁選的引擎和即時顯示。語言是給引擎的提示，中英夾雜選中文就好。")
        }
    }

    private func languageChoices(_ mode: DictationModeConfig) -> [String] {
        var codes = ModeContext.languageCodes
        if let custom = mode.recognition.language.customValue, !codes.contains(custom) { codes.append(custom) }
        return codes
    }

    // MARK: 文字格式

    private func formatSection(_ mode: DictationModeConfig, resolved: ResolvedModeConfig) -> some View {
        let format = mode.textFormat
        let isCustom = !(format.forceTraditional.followsDefault && format.spaceBetweenCJKAndLatin.followsDefault
            && format.punctuationRule.followsDefault && format.punctuationLimit.followsDefault)
        return Section {
            Picker(selection: Binding(get: { isCustom }, set: { custom in
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
            } label: {
                Text("格式")
            }
            .pickerStyle(.segmented)

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
            SectionHeader("文字格式", info: "繁體、中英文空格和標點。「跟隨預設」用設定頁的輸出和標點符號設定。")
        }
    }

    private func limitChoices(_ current: Int) -> [Int] {
        AppSettings.punctuationLimitChoices.contains(current) ? AppSettings.punctuationLimitChoices
            : AppSettings.punctuationLimitChoices + [current]
    }

    // MARK: AI 處理

    private static let newPromptTag = "__new_prompt__"

    private func aiSection(_ mode: DictationModeConfig, resolved: ResolvedModeConfig, template: PromptTemplate,
                           context: ModeContext) -> some View {
        let defaults = context.defaults
        let needsAI = template.kind != .dictation
        let globalAI = defaults.polishProvider == .off ? "關" : defaults.polishProvider.displayName
        return Section {
            if !needsAI {
                Picker(selection: binding(\.ai.enabled)) {
                    Text("跟隨預設（\(globalAI)）").tag(ModeOverride<Bool>.followDefault)
                    Divider()
                    Text("開").tag(ModeOverride<Bool>.custom(true))
                    Text("關").tag(ModeOverride<Bool>.custom(false))
                } label: {
                    HStack(spacing: 4) {
                        Text("AI 整理")
                        InfoButton("關掉時只做基本整理：去掉贅字、轉成繁體、套用字典。")
                    }
                }
                .pickerStyle(.menu)
            }
            if let llm = resolved.llm {
                providerPicker(mode, llm: llm, context: context)
                promptRow(mode, template: template)
                if template.kind == .translate {
                    Picker("翻譯成", selection: binding(\.ai.translateLanguageID)) {
                        Text("跟隨預設（\(settings.translateLanguage.displayName)）").tag(ModeOverride<String>.followDefault)
                        Divider()
                        ForEach(TranslateLanguage.all) { language in
                            Text(language.displayName).tag(ModeOverride<String>.custom(language.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        } header: {
            SectionHeader("AI 處理") {
                InfoText("用 AI 去掉口誤、整理標點和段落，或依提示詞改寫、翻譯。")
                InfoText("「跟隨預設」用設定頁的 AI 潤飾。翻譯、改寫這類提示詞一定會用 AI。")
            }
        }
    }

    private func providerPicker(_ mode: DictationModeConfig, llm: ResolvedLLM, context: ModeContext) -> some View {
        var followed = mode
        followed.ai.provider = .followDefault
        let followName = context.resolved(followed).llm.map(context.providerName) ?? PolishProviderKind.groq.displayName
        let missing = context.llmKeyMissing(llm)
        let chosen = mode.ai.provider.customValue.flatMap { $0 == .off ? nil : $0 }
        let fallback = chosen.flatMap { kind -> String? in
            guard let key = kind.requiredKey, !settings.hasKey(key), !missing else { return nil }
            return "沒有 \(kind.displayName) 的 key，改用 \(context.providerName(llm))"
        }
        return Picker(selection: binding(\.ai.provider)) {
            Text("跟隨預設（\(followName)）").tag(ModeOverride<PolishProviderKind>.followDefault)
            Divider()
            ForEach([PolishProviderKind.groq, .anthropic], id: \.self) { kind in
                Text(kind.displayName).tag(ModeOverride<PolishProviderKind>.custom(kind))
            }
        } label: {
            RowTitle("服務", caption: missing ? "需要 Groq 或 Anthropic 的 API key，到設定填入" : fallback,
                     captionIsProblem: missing || fallback != nil)
        }
        .pickerStyle(.menu)
    }

    private func promptRow(_ mode: DictationModeConfig, template: PromptTemplate) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker("提示詞", selection: Binding(get: { template.id }, set: { id in
                    if id == Self.newPromptTag {
                        editingPrompt = PromptEditorTarget(promptID: nil, kind: template.kind) { newID in
                            update { $0.ai.promptID = newID }
                        }
                    } else {
                        update { $0.ai.promptID = id }
                    }
                })) {
                    ForEach(prompts.prompts) { prompt in
                        Text(prompt.name).tag(prompt.id)
                    }
                    Divider()
                    Text("新增提示詞…").tag(Self.newPromptTag)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Button("編輯…") {
                    editingPrompt = PromptEditorTarget(promptID: template.id, kind: template.kind) { newID in
                        update { $0.ai.promptID = newID }
                    }
                }
                .buttonStyle(.bordered)
                .help("編輯「\(template.name)」")
            }
        } label: {
            RowTitle("提示詞", caption: ModeContext.promptKindName(template.kind))
        }
    }

    // MARK: 輸出

    private func outputSection(_ mode: DictationModeConfig, template: PromptTemplate, context: ModeContext) -> some View {
        let isCurrent = context.currentModeID == mode.id
        return Section {
            LabeledContent("結果") {
                Text(template.kind == .rewrite ? "取代選取的文字" : "貼到游標處")
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                if isCurrent {
                    StatusBadge(isOn: true, onText: "是")
                } else {
                    Button("設為預設") { settings.setCurrentMode(mode.id, store: store) }
                        .buttonStyle(.bordered)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("預設模式")
                    InfoButton("按主要快捷鍵或選單的「開始聽寫」時用這個模式。選單列也可以切換。")
                }
            }
        } header: {
            Text("輸出")
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
        copy.name = String("\(mode.name) 副本".prefix(Self.maxNameLength))
        copy.trigger.hotkey = nil
        try? store.update(copy)
        DiagLog.log("modes", "mode duplicated from=\(mode.id) id=\(copy.id)")
    }
}

/// A prompt to edit in a sheet: an existing one, or a new one (`promptID` nil) of `kind`.
struct PromptEditorTarget: Identifiable {
    let id = UUID()
    var promptID: String?
    var kind: PromptKind = .dictation
    /// The prompt the editor ended on (saved, or a copy it made), for the mode that opened it.
    var onSaved: ((String) -> Void)?
}
