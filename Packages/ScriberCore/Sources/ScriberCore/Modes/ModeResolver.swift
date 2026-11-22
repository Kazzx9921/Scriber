import Foundation
import ScriberShared

/// The global settings every mode starts from (設定 becomes 「預設值」, PRD §9.4). One snapshot per
/// run, so a settings change mid-run cannot mix configurations. Before modes this was the
/// pipeline's whole configuration (`PipelineConfig`, still its name inside the package).
public struct ModeDefaults: Sendable, Equatable {
    public var sttProvider: STTProviderKind
    /// The global 「AI 潤飾」 setting: `.off`, or the provider plain dictation is polished with.
    public var polishProvider: PolishProviderKind
    public var forceTraditional: Bool
    public var spaceBetweenCJKAndLatin: Bool
    /// Punctuation preference for finished text (see `PunctuationStyler`).
    public var punctuationRule: PunctuationRule = .dropFinalPeriod
    public var punctuationLimit: Int = 20
    /// Prompt name of the translate language, e.g. "English".
    public var translateTarget: String
    /// STT language hint. Mixed zh/en speech is the main use case, and Whisper needs "zh" to stay in Chinese.
    public var languageCode: String? = "zh"
    /// 即時顯示文字 (only applies with ElevenLabs Scribe).
    public var realtimeEnabled: Bool = false
    /// Transcripts with at most this many units (CJK characters or Latin words) skip the LLM.
    public var shortTranscriptLimit: Int = 5
    /// Hard cap on the LLM call, on top of the provider's own timeout.
    public var polishTimeout: TimeInterval = 4.5

    public init(sttProvider: STTProviderKind, polishProvider: PolishProviderKind, forceTraditional: Bool,
                spaceBetweenCJKAndLatin: Bool, translateTarget: String) {
        self.sttProvider = sttProvider; self.polishProvider = polishProvider
        self.forceTraditional = forceTraditional; self.spaceBetweenCJKAndLatin = spaceBetweenCJKAndLatin
        self.translateTarget = translateTarget
    }

    public init(settings: AppSettings) {
        self.init(sttProvider: settings.sttProvider, polishProvider: settings.polishProvider,
                  forceTraditional: settings.forceTraditional,
                  spaceBetweenCJKAndLatin: settings.spaceBetweenCJKAndLatin,
                  translateTarget: settings.translateTarget)
        punctuationRule = settings.punctuationRule
        punctuationLimit = settings.punctuationLimit
        realtimeEnabled = settings.realtimeEnabled
    }
}

/// How much context (情境感知, PRD §7.6) goes along with the transcript. The apps cap what they read
/// to the same lengths (the prompt builder caps again).
public enum ModeContextLimit {
    /// Longest clipboard / selected-text context (characters). A rewrite's own selection is not capped.
    public static let characters = 4000
    /// Longest app name (characters).
    public static let appName = 80
}

/// The prompt a resolved mode uses.
public struct ResolvedPrompt: Sendable, Equatable {
    public var id: String
    public var kind: PromptKind
    /// The user-editable text, variables not yet replaced.
    public var body: String
    /// A shipped prompt exactly as shipped (its examples are added; no "your text cannot override
    /// the rules" reminder is needed).
    public var isPristineBuiltIn: Bool
    public var builtInID: BuiltInPromptID?

    public init(_ template: PromptTemplate) {
        id = template.id; kind = template.kind; body = template.body
        isPristineBuiltIn = template.isPristineBuiltIn; builtInID = template.builtInID
    }

    /// The shipped prompt for a pre-modes request mode (`PolishContext` without a prompt).
    static func legacy(_ mode: DictationMode) -> ResolvedPrompt {
        switch mode {
        case .dictate: return ResolvedPrompt(BuiltInPrompts.template(.standard))
        case .translate: return ResolvedPrompt(BuiltInPrompts.template(.translate))
        case .edit: return ResolvedPrompt(BuiltInPrompts.template(.rewrite))
        }
    }
}

/// The LLM step of a resolved mode.
public struct ResolvedLLM: Sendable, Equatable {
    /// Tried in order; the first one with a usable key runs.
    public var candidates: [PolishProviderKind]
    /// When no candidate has a key: true → `PolishError.requiresLLM` before any STT;
    /// false → rule-based cleanup (plain dictation following the global 「AI 潤飾」 switch).
    public var required: Bool
    /// Stored in the mode; not sent to the provider yet (M2 adds per-model request shapes).
    public var model: String?
    public var prompt: ResolvedPrompt
}

/// A mode resolved against the global defaults: everything one dictation run needs. Built by
/// `ModeResolver`; consumed by `DictationPipeline`; `output` / `autoSend` / `realtimeEnabled` are
/// for the caller (pasting, the answer panel, the real-time session).
public struct ResolvedModeConfig: Sendable, Equatable {
    /// The mode that runs.
    public var modeID: String
    /// The mode the request asked for. Differs from `modeID` when 改寫 had no selection and the
    /// default mode ran instead.
    public var requestedModeID: String
    /// What the AI does. `.dictation` when the AI is off (rule-based cleanup only).
    public var task: PromptKind

    // 辨識
    public var sttProvider: STTProviderKind
    /// nil = let the engine detect the language.
    public var languageCode: String?
    public var realtimeEnabled: Bool

    // 文字格式
    public var forceTraditional: Bool
    public var spaceBetweenCJKAndLatin: Bool
    public var punctuationRule: PunctuationRule
    public var punctuationLimit: Int
    /// Prompt name of the translate target (`{{language}}`), e.g. "English".
    public var translateTarget: String

    // AI 處理
    /// nil: no LLM, rule-based cleanup.
    public var llm: ResolvedLLM?
    /// What may be sent to the AI besides the transcript (none when `llm` is nil; the selected
    /// text always for `task == .rewrite`).
    public var context: ModeContextFlags

    // 輸出
    public var output: ModeOutput
    public var autoSend: ModeAutoSend

    public var shortTranscriptLimit: Int
    public var polishTimeout: TimeInterval

    // MARK: Rules that depend on the task (unchanged from before modes)

    /// The closest pre-modes request mode (history, error messages). 助理 maps to `.dictate`.
    public var legacyMode: DictationMode {
        switch task {
        case .dictation, .assistant: return .dictate
        case .translate: return .translate
        case .rewrite: return .edit
        }
    }

    /// Only dictation skips the LLM for very short transcripts ("好", "OK 收到").
    var skipsLLMForShortTranscripts: Bool { task == .dictation }
    /// Only dictation falls back to rule-based cleanup when the LLM fails: for translate / rewrite
    /// / assistant the fallback would insert untranslated text, or replace the selection with the
    /// spoken instruction.
    var fallsBackToRuleBasedCleanup: Bool { task == .dictation }
    /// The short-message punctuation rule is for the user's own messages; a rewrite keeps the
    /// original text's punctuation and an answer is not a chat message.
    var appliesPunctuationRule: Bool { task == .dictation || task == .translate }
    /// Translating into a non-Chinese language skips the Traditional conversion.
    var convertsToTraditional: Bool {
        forceTraditional && !(task == .translate && !DictationPipeline.isChineseTarget(translateTarget))
    }
}

/// Mode + global defaults + prompt library → `ResolvedModeConfig`.
///
/// Rules (PRD §2, §9.4):
/// - every "follow default" field takes the global setting;
/// - prompts of kind translate / rewrite / assistant always run the LLM, using the mode's provider,
///   else the global one, else any provider with a key (Groq, then Anthropic) — the same rule
///   translate and 說話改字 used before modes;
/// - AI "follow default" on a dictation prompt does exactly what plain dictation did: polish with
///   the global provider when 「AI 潤飾」 is on, rule-based cleanup when it is off or has no key;
/// - AI explicitly on (潤飾, Email…) uses the provider rule above and needs a key;
/// - 改寫 without a selection is plain dictation: the default mode runs instead;
/// - a prompt id that no longer exists falls back to the mode's shipped prompt (預設 for user modes).
public enum ModeResolver {

    /// The mode a request asks for: `modeID` when it names an existing mode, else the built-in mode
    /// for the pre-modes `mode` (`.translate` → 翻譯, `.edit` → 改寫), else the default mode.
    /// Disabled modes are returned too: whether to offer a mode is the caller's decision.
    public static func mode(for request: DictationRequest, in modes: [DictationModeConfig]) -> DictationModeConfig {
        let modes = ModeStore.normalized(modes)
        if let id = request.modeID, let mode = modes.first(where: { $0.id == id }) { return mode }
        if let builtIn = BuiltInModeID.forLegacy(request.mode),
           let mode = modes.first(where: { $0.id == builtIn.rawValue }) { return mode }
        return ModeStore.defaultMode(in: modes)
    }

    /// Enabled modes that list `bundleID` under 自動套用的 App (macOS, PRD §7.2), in list order:
    /// when several match, the earlier one wins. Bundle ids compare case-insensitively. Whether a
    /// candidate can run right now (keys) is the caller's decision.
    public static func autoApplyCandidates(for bundleID: String?, in modes: [DictationModeConfig]) -> [DictationModeConfig] {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else { return [] }
        return ModeStore.normalized(modes).filter { mode in
            mode.isEnabled && mode.trigger.appBundleIDs.contains { $0.lowercased() == id }
        }
    }

    /// The configuration a request runs with (selection known).
    public static func resolve(_ request: DictationRequest, modes: [DictationModeConfig], prompts: [PromptTemplate],
                               defaults: ModeDefaults) -> ResolvedModeConfig {
        let modes = ModeStore.normalized(modes)
        let requested = mode(for: request, in: modes)
        var resolved = resolve(requested, prompts: prompts, defaults: defaults)
        if resolved.task == .rewrite, !request.hasSelection {
            // 改寫 with nothing selected: what the normal hotkey would do.
            var plain = resolve(ModeStore.defaultMode(in: modes), prompts: prompts, defaults: defaults)
            if plain.task == .rewrite {
                plain = resolve(.builtIn(.dictate), prompts: prompts, defaults: defaults)
            }
            plain.requestedModeID = requested.id
            resolved = plain
        }
        if resolved.output == .replaceSelection, !request.hasSelection { resolved.output = .paste }
        return resolved
    }

    /// The configuration of `mode` when it has what it needs (a selection, for 改寫).
    public static func resolve(_ mode: DictationModeConfig, prompts: [PromptTemplate],
                               defaults: ModeDefaults) -> ResolvedModeConfig {
        let template = prompt(for: mode, in: prompts)
        let llm = resolveLLM(mode, template: template, defaults: defaults)
        let task: PromptKind = llm == nil ? .dictation : template.kind
        var context = ModeContextFlags.none
        if llm != nil {
            context = mode.context
            if task == .rewrite { context.selectedText = true }
        }
        let format = mode.textFormat
        return ResolvedModeConfig(
            modeID: mode.id, requestedModeID: mode.id, task: task,
            sttProvider: mode.recognition.engine.resolved(defaults.sttProvider),
            languageCode: languageCode(mode.recognition.language, defaults: defaults),
            realtimeEnabled: mode.recognition.realtime.resolved(defaults.realtimeEnabled),
            forceTraditional: format.forceTraditional.resolved(defaults.forceTraditional),
            spaceBetweenCJKAndLatin: format.spaceBetweenCJKAndLatin.resolved(defaults.spaceBetweenCJKAndLatin),
            punctuationRule: format.punctuationRule.resolved(defaults.punctuationRule),
            punctuationLimit: max(0, format.punctuationLimit.resolved(defaults.punctuationLimit)),
            translateTarget: mode.ai.translateLanguageID.customValue.map { TranslateLanguage.find($0).promptName }
                ?? defaults.translateTarget,
            llm: llm, context: context, output: mode.output, autoSend: mode.autoSend,
            shortTranscriptLimit: defaults.shortTranscriptLimit,
            polishTimeout: task == .assistant ? max(defaults.polishTimeout, assistantTimeout) : defaults.polishTimeout)
    }

    /// Answers are longer than a cleaned-up sentence; the dictation deadline would cut them off.
    static let assistantTimeout: TimeInterval = 30

    /// The prompt a mode uses: its own, else its shipped one, else 預設.
    public static func prompt(for mode: DictationModeConfig, in prompts: [PromptTemplate]) -> PromptTemplate {
        let library = prompts.isEmpty ? BuiltInPrompts.all : prompts
        if let id = mode.ai.promptID, let template = library.first(where: { $0.id == id }) { return template }
        let shippedID = mode.builtInID?.promptID ?? BuiltInPromptID.standard.rawValue
        return library.first { $0.id == shippedID } ?? BuiltInPrompts.template(BuiltInPromptID(rawValue: shippedID) ?? .standard)
    }

    private static func resolveLLM(_ mode: DictationModeConfig, template: PromptTemplate,
                                   defaults: ModeDefaults) -> ResolvedLLM? {
        let global: PolishProviderKind? = defaults.polishProvider == .off ? nil : defaults.polishProvider
        let chosen: PolishProviderKind? = mode.ai.provider.customValue.flatMap { $0 == .off ? nil : $0 }
        let needsLLM = template.kind != .dictation
        let prompt = ResolvedPrompt(template)
        switch (mode.ai.enabled, needsLLM) {
        case (.followDefault, false):
            // Plain dictation as before modes: the global switch decides, no other provider is tried.
            guard let global else { return nil }
            return ResolvedLLM(candidates: [chosen ?? global], required: false, model: mode.ai.model, prompt: prompt)
        case (.custom(false), false):
            return nil
        default:
            let preferred: [PolishProviderKind] = (chosen ?? global).map { [$0] } ?? []
            let candidates = preferred + [PolishProviderKind.groq, .anthropic].filter { !preferred.contains($0) }
            return ResolvedLLM(candidates: candidates, required: true, model: mode.ai.model, prompt: prompt)
        }
    }

    private static func languageCode(_ setting: ModeOverride<String>, defaults: ModeDefaults) -> String? {
        guard let value = setting.customValue else { return defaults.languageCode }
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty || code == ModeRecognition.automatic ? nil : code
    }
}

public extension ModeStore {
    /// Resolves a request against this store, the prompt library and the global settings.
    func resolve(_ request: DictationRequest, settings: AppSettings = .shared,
                 prompts: PromptLibrary = .shared) -> ResolvedModeConfig {
        ModeResolver.resolve(request, modes: snapshot(), prompts: prompts.snapshot(), defaults: ModeDefaults(settings: settings))
    }
}
