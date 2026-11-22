import Foundation
import ScriberShared

/// The iOS keyboard's mode key (docs/PRD-模式.md §6.2, M4) as plain data: which modes it offers,
/// which one the mic uses now, what a tap switches to, what the long press lists, the request a
/// tap on the mic sends, and how the result reaches the field. Pure functions of the modes, the
/// prompt library, the recently-used list and whether an AI key exists, so the keyboard and the
/// tests share one set of rules.
///
/// - **Offered**: enabled modes whose prompt is not 改寫類. A selection is rewritten by 改寫 on its
///   own (as before modes), so a rewrite mode in the list would only run plain dictation.
///   助理 is offered: iOS has no answer panel, so the answer is typed at the cursor (`Delivery`).
/// - **Current** (what the mic uses): the most recently used offered mode that can run (modes that
///   need the AI need a Groq or Anthropic key), else the **base** mode: the default mode, or 聽寫,
///   or the first offered mode when the default is not offered.
/// - **Partner** (what a tap switches to): the next candidate after the current one — recents,
///   then the base mode, then 翻譯, then the list order. Nothing used yet → 聽寫 ↔ 翻譯, exactly the
///   pre-modes translate key. A partner that needs a missing key is still the partner (the key is
///   dimmed and a tap explains), like the translate key without a key.
/// - **Menu** (long press): up to `menuLimit` offered modes in the user's list order; the current
///   mode is always in it. The first translate mode that follows the global language lists the
///   quick languages instead of one cell (`languageItemID`).
/// - **Request**: a selection with 改寫 enabled → 改寫 with the selection; otherwise the current
///   mode by id. The keyboard never sends clipboard text, app names or (outside 改寫) the selection.
/// - **Delivery**: `copyOnly` → copy; paste, replaceSelection and answer → typed at the cursor.
///   Auto-send is a Mac feature and is ignored.
public enum KeyboardModes {
    /// Most modes the long press lists (PRD: "常用的三到四個").
    public static let menuLimit = 4

    /// One mode as the keyboard shows and runs it.
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// SF Symbol name.
        public var icon: String
        /// What the AI does when it runs (`.dictation` when the AI is off).
        public var task: PromptKind
        /// `TranslateLanguage` id of the target, for translate modes: the mode's own language, else
        /// the global one (which the keyboard switches).
        public var translateLanguageID: String?
        /// A translate mode following the global language: the keyboard can pick its language.
        public var followsKeyboardLanguage: Bool
        /// Runs the AI whatever 「AI 潤飾」 says (翻譯, 潤飾, Email, 助理…).
        public var needsAIKey: Bool
        /// Needs the AI and no Groq / Anthropic key is visible: choosing it explains instead.
        public var isBlocked: Bool
        /// The engine it records with (resolved against the global default).
        public var sttProvider: STTProviderKind
        /// What happens to its result (resolved; see `delivery(for:)`).
        public var output: ModeOutput

        public var isTranslate: Bool { task == .translate }
    }

    public struct State: Equatable, Sendable {
        /// What the mic uses now. nil only when no mode can be offered (then the request falls back
        /// to the default mode).
        public var current: Item?
        /// What a tap on the mode key switches to.
        public var partner: Item?
        /// The long-press list, in list order.
        public var menu: [Item]
        /// The calm mode: the key looks like the old translate key switched off while it is current.
        public var baseID: String?
        /// 改寫 is enabled: a selection makes the mic rewrite it.
        public var rewriteOnSelection: Bool
        /// The menu item that lists the quick languages.
        public var languageItemID: String?

        public init(current: Item?, partner: Item?, menu: [Item], baseID: String?, rewriteOnSelection: Bool,
                    languageItemID: String?) {
            self.current = current; self.partner = partner; self.menu = menu; self.baseID = baseID
            self.rewriteOnSelection = rewriteOnSelection; self.languageItemID = languageItemID
        }

        /// The base mode is current: the key is drawn plain (showing what a tap switches to).
        public var isCalm: Bool { current != nil && current?.id == baseID }
        /// Something to switch to, or languages to pick.
        public var showsKey: Bool { partner != nil || languageItemID != nil }

        public func item(id: String) -> Item? {
            if current?.id == id { return current }
            if partner?.id == id { return partner }
            return menu.first { $0.id == id }
        }
    }

    // MARK: Offered modes

    /// Enabled, non-rewrite modes in list order.
    public static func offered(_ modes: [DictationModeConfig], prompts: [PromptTemplate]) -> [DictationModeConfig] {
        ModeStore.normalized(modes).filter { mode in
            mode.isEnabled && ModeResolver.prompt(for: mode, in: prompts).kind != .rewrite
        }
    }

    // MARK: State

    /// - Parameters:
    ///   - modes: the stored modes (normalized here, so `[]` means the shipped ones).
    ///   - recents: `ModeStore.storedRecentIDs`, most recent first; unknown, disabled and rewrite ids are skipped.
    ///   - keyboardLanguageID: the global translate language (`AppSettings.translateLanguageID`).
    ///   - hasLLMKey: whether a Groq or Anthropic key is visible; nil when the keyboard cannot tell
    ///     (then nothing is blocked and the app reports a real problem).
    public static func state(modes: [DictationModeConfig], prompts: [PromptTemplate], defaults: ModeDefaults,
                             recents: [String], keyboardLanguageID: String, hasLLMKey: Bool?) -> State {
        let all = ModeStore.normalized(modes)
        let library = prompts.isEmpty ? PromptLibrary.builtIns : prompts
        let items = offered(all, prompts: library).map {
            item($0, prompts: library, defaults: defaults, keyboardLanguageID: keyboardLanguageID, hasLLMKey: hasLLMKey)
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let defaultID = ModeStore.defaultMode(in: all).id
        let dictateID = BuiltInModeID.dictate.rawValue
        let baseID = byID[defaultID] != nil ? defaultID : (byID[dictateID] != nil ? dictateID : items.first?.id)

        var candidates: [String] = []
        for id in recents + [baseID, BuiltInModeID.translate.rawValue].compactMap({ $0 }) + items.map(\.id)
            where byID[id] != nil && !candidates.contains(id) {
            candidates.append(id)
        }
        let currentID = candidates.first { byID[$0]?.isBlocked == false } ?? baseID
        let current = currentID.flatMap { byID[$0] }
        let partner = candidates.first { $0 != currentID }.flatMap { byID[$0] }

        var menuIDs = Array(items.prefix(menuLimit).map(\.id))
        if let currentID, byID[currentID] != nil, !menuIDs.contains(currentID) {
            menuIDs.removeLast()
            menuIDs.append(currentID)
        }
        let menu = items.filter { menuIDs.contains($0.id) }
        return State(current: current, partner: partner, menu: menu, baseID: baseID,
                     rewriteOnSelection: all.contains { $0.id == BuiltInModeID.rewrite.rawValue && $0.isEnabled },
                     languageItemID: menu.first(where: \.followsKeyboardLanguage)?.id)
    }

    static func item(_ mode: DictationModeConfig, prompts: [PromptTemplate], defaults: ModeDefaults,
                     keyboardLanguageID: String, hasLLMKey: Bool?) -> Item {
        let resolved = ModeResolver.resolve(mode, prompts: prompts, defaults: defaults)
        let isTranslate = resolved.task == .translate
        let own = mode.ai.translateLanguageID.customValue
        let needsAI = resolved.llm?.required == true
        return Item(id: mode.id, name: mode.name, icon: mode.icon, task: resolved.task,
                    translateLanguageID: isTranslate ? TranslateLanguage.find(own ?? keyboardLanguageID).id : nil,
                    followsKeyboardLanguage: isTranslate && own == nil,
                    needsAIKey: needsAI, isBlocked: needsAI && hasLLMKey == false,
                    sttProvider: resolved.sttProvider, output: resolved.output)
    }

    // MARK: Request

    /// What a tap on the mic sends. `selectedText`: the field's selection (empty = none).
    public static func request(_ state: State, selectedText: String?, fieldHint: FieldHint,
                               id: String = UUID().uuidString) -> DictationRequest {
        if let selected = selectedText, !selected.isEmpty, state.rewriteOnSelection {
            return DictationRequest(id: id, mode: .edit, selectedText: selected, fieldHint: fieldHint,
                                    modeID: BuiltInModeID.rewrite.rawValue)
        }
        guard let current = state.current else {
            return DictationRequest(id: id, mode: .dictate, fieldHint: fieldHint)
        }
        // `mode` is only the fallback for a mode deleted before the app runs the request.
        return DictationRequest(id: id, mode: current.isTranslate ? .translate : .dictate, fieldHint: fieldHint,
                                modeID: current.id)
    }

    // MARK: Delivery

    /// How a finished result reaches the field on iOS.
    public enum Delivery: String, Sendable {
        /// Typed at the cursor (replacing a selection, like any typing).
        case insert
        /// Put on the clipboard; the mic pill says 已複製.
        case copy
    }

    /// iOS has no answer panel and no auto-send: only 「只複製」 differs from typing.
    public static func delivery(for output: ModeOutput) -> Delivery {
        output == .copyOnly ? .copy : .insert
    }

    /// The delivery of `request` as the pipeline will resolve it.
    public static func delivery(for request: DictationRequest, modes: [DictationModeConfig],
                                prompts: [PromptTemplate], defaults: ModeDefaults) -> Delivery {
        delivery(for: ModeResolver.resolve(request, modes: modes, prompts: prompts, defaults: defaults).output)
    }
}

public extension ModeStore {
    /// The keyboard's mode key against this store, its recently-used list, the prompt library and
    /// the global settings. Cheap: two small JSON files (re-read only when they changed) and defaults.
    func keyboardState(settings: AppSettings = .shared, prompts: PromptLibrary = .shared,
                       keyboardLanguageID: String, hasLLMKey: Bool?) -> KeyboardModes.State {
        KeyboardModes.state(modes: snapshot(), prompts: prompts.snapshot(), defaults: ModeDefaults(settings: settings),
                            recents: storedRecentIDs, keyboardLanguageID: keyboardLanguageID, hasLLMKey: hasLLMKey)
    }

    /// How the result of `request` reaches the field (see `KeyboardModes.delivery`).
    func keyboardDelivery(for request: DictationRequest, settings: AppSettings = .shared,
                          prompts: PromptLibrary = .shared) -> KeyboardModes.Delivery {
        KeyboardModes.delivery(for: request, modes: snapshot(), prompts: prompts.snapshot(),
                               defaults: ModeDefaults(settings: settings))
    }
}
