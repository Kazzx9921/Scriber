import Foundation
import ScriberCore
import ScriberShared

/// What one press of a hotkey (or 開始聽寫 in the menu) starts: the mode that runs, the request for
/// the pipeline, and what the controller checks before the microphone opens. Pure: built from the
/// modes, the prompt library and the global defaults, so the routing from a key to a request is
/// tested without the app.
///
/// The request keeps the pre-modes form whenever that already picks the same mode: plain 聽寫 is
/// `DictationRequest()`, 翻譯 `DictationRequest(mode: .translate)`, 說話改字 / 改寫
/// `DictationRequest(mode: .edit)` — exactly what those keys sent before modes. Other modes carry
/// their id (`modeID`).
///
/// Which mode (docs/PRD-模式.md §7.2): a mode's own hotkey > 自動套用 (the app in front when the main
/// hotkey is pressed) > the current mode (the default mode, or 翻譯 while the menu's lock is on).
/// An auto-apply mode that cannot run right now (no AI key, engine without a key) is passed over:
/// the next matching mode, else the current mode, runs instead of an error.
struct DictationStart: Equatable, Sendable {
    /// The mode that runs.
    var modeID: String
    /// Name and SF Symbol for the HUD and the menu's status line (never logged).
    var name: String
    var icon: String
    /// The pre-modes request mode: history, wording, the closest legacy behaviour.
    var legacyMode: DictationMode
    /// Set when `legacyMode` alone would pick another mode.
    var requestModeID: String?
    /// The mode resolved against the defaults (selection assumed): engine, real-time, AI.
    var resolved: ResolvedModeConfig
    /// Short language label for translate modes ("EN", "日").
    var badge: String?
    /// The bundle id of the app in front when it picked this mode instead of the current one.
    var autoAppliedFor: String?
    /// Auto-apply modes passed over, as "<mode id>:<reason>" (for the log).
    var autoApplySkipped: [String] = []

    /// Reads the selected text at the start: what 改寫 rewrites, or context a mode asked for.
    var needsSelection: Bool { resolved.context.selectedText }
    /// The selection is what the mode works on (改寫): without one the default mode runs instead,
    /// and the ⌘C fallback may be used to find it. Context-only selections never post ⌘C.
    var selectionRequired: Bool { resolved.task == .rewrite }
    /// The AI must run: refused before recording when there is no Groq / Anthropic key.
    var requiresLLM: Bool { resolved.llm?.required == true }
    /// Plain 聽寫 shows nothing extra in the HUD; every other mode shows its icon (or language), and
    /// so does a mode the app in front picked (so the user sees why the result looks different).
    var showsMark: Bool { modeID != BuiltInModeID.dictate.rawValue || autoAppliedFor != nil }
    /// The context the controller has to read at the start (only what the mode sends to its AI).
    var wantsClipboard: Bool { resolved.context.clipboard }
    var wantsAppName: Bool { resolved.context.appName }

    /// What was read at the start for the mode's 情境 (PRD §7.6).
    struct Context: Equatable, Sendable {
        var appName: String?
        var clipboard: String?

        init(appName: String? = nil, clipboard: String? = nil) {
            self.appName = appName; self.clipboard = clipboard
        }
    }

    /// The request for the pipeline. Context goes in only when the mode asks for it (and its AI
    /// runs: `resolved.context` is empty otherwise), capped to `ModeContextLimit`.
    func request(id: String = UUID().uuidString, context: Context = Context()) -> DictationRequest {
        var request = DictationRequest(id: id, mode: legacyMode, modeID: requestModeID)
        if wantsAppName, let name = Self.cleaned(context.appName, limit: ModeContextLimit.appName) {
            request.appName = name
        }
        if wantsClipboard, let text = Self.cleaned(context.clipboard, limit: ModeContextLimit.characters) {
            request.clipboardText = text
        }
        return request
    }

    private static func cleaned(_ text: String?, limit: Int) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    /// nil when the variant names a mode that does not exist (deleted meanwhile).
    /// `frontmostBundleID`: the app in front at the press (自動套用; only for `.dictate`).
    static func plan(_ variant: HotkeyVariant, translateLocked: Bool, modes: [DictationModeConfig],
                     prompts: [PromptTemplate], defaults: ModeDefaults, frontmostBundleID: String? = nil,
                     readiness: ModeReadiness = .everything) -> DictationStart? {
        var running: DictationModeConfig
        var autoApplied: String?
        var skipped: [String] = []
        switch variant {
        case .dictate:
            let translate = modes.first { $0.id == BuiltInModeID.translate.rawValue }
            if translateLocked, let translate, translate.isEnabled {
                running = translate
            } else {
                running = ModeResolver.mode(for: DictationRequest(), in: modes)
            }
            let current = running
            for candidate in ModeResolver.autoApplyCandidates(for: frontmostBundleID, in: modes) {
                let resolved = ModeResolver.resolve(candidate, prompts: prompts, defaults: defaults)
                if let reason = readiness.problem(resolved) {
                    skipped.append("\(candidate.id):\(reason)")
                    continue
                }
                running = candidate
                if candidate.id != current.id { autoApplied = frontmostBundleID }
                break
            }
        case .edit, .translate, .mode:
            guard let id = variant.modeID, let mode = modes.first(where: { $0.id == id }) else { return nil }
            running = mode
        }
        let resolved = ModeResolver.resolve(running, prompts: prompts, defaults: defaults)
        let legacy = resolved.legacyMode
        let legacyPicksIt = ModeResolver.mode(for: DictationRequest(mode: legacy), in: modes).id == running.id
        let badge = resolved.task == .translate
            ? TranslateLanguage.all.first { $0.promptName == resolved.translateTarget }?.shortLabel
            : nil
        let icon = running.icon.trimmingCharacters(in: .whitespaces)
        return DictationStart(modeID: running.id, name: running.name, icon: icon.isEmpty ? "mic" : icon,
                              legacyMode: legacy, requestModeID: legacyPicksIt ? nil : running.id,
                              resolved: resolved, badge: badge, autoAppliedFor: autoApplied,
                              autoApplySkipped: skipped)
    }
}

/// What can run right now, for 自動套用: an auto-apply mode that would only end in 「需要 API key」
/// is passed over instead.
struct ModeReadiness: Equatable, Sendable {
    /// A Groq or Anthropic key is stored.
    var hasLLMKey: Bool
    /// Engines with their key (and, for the custom engine, its settings).
    var readyEngines: Set<STTProviderKind>

    static let everything = ModeReadiness(hasLLMKey: true, readyEngines: Set(STTProviderKind.allCases))

    /// Why `resolved` cannot run ("engine", "no-llm-key"), nil when it can.
    func problem(_ resolved: ResolvedModeConfig) -> String? {
        if !readyEngines.contains(resolved.sttProvider) { return "engine" }
        if resolved.llm?.required == true, !hasLLMKey { return "no-llm-key" }
        return nil
    }
}
