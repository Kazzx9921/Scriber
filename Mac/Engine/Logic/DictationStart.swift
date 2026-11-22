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

    /// Reads the selected text at the start (說話改字 / modes with a rewrite prompt).
    var needsSelection: Bool { resolved.task == .rewrite }
    /// The AI must run: refused before recording when there is no Groq / Anthropic key.
    var requiresLLM: Bool { resolved.llm?.required == true }
    /// Plain 聽寫 shows nothing extra in the HUD; every other mode shows its icon (or language).
    var showsMark: Bool { modeID != BuiltInModeID.dictate.rawValue }

    func request(id: String = UUID().uuidString) -> DictationRequest {
        DictationRequest(id: id, mode: legacyMode, modeID: requestModeID)
    }

    /// nil when the variant names a mode that does not exist (deleted meanwhile).
    static func plan(_ variant: HotkeyVariant, translateLocked: Bool, modes: [DictationModeConfig],
                     prompts: [PromptTemplate], defaults: ModeDefaults) -> DictationStart? {
        let running: DictationModeConfig
        switch variant {
        case .dictate:
            let translate = modes.first { $0.id == BuiltInModeID.translate.rawValue }
            if translateLocked, let translate, translate.isEnabled {
                running = translate
            } else {
                running = ModeResolver.mode(for: DictationRequest(), in: modes)
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
                              resolved: resolved, badge: badge)
    }
}
