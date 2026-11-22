import SwiftUI
import ScriberCore
import ScriberShared

/// What the modes UI shows about a mode — resolved against the current settings, keys and hotkey
/// state — in a few words (zh-Hant, Taiwan). Shared by the cards, the editor and the menu.
@MainActor
struct ModeContext {
    let settings: MacSettings
    let modes: [DictationModeConfig]
    let prompts: [PromptTemplate]
    let accessibilityTrusted: Bool
    let hotkey: HotkeyRuntimeState

    var defaults: ModeDefaults { settings.modeDefaults }

    func resolved(_ mode: DictationModeConfig) -> ResolvedModeConfig {
        ModeResolver.resolve(mode, prompts: prompts, defaults: defaults)
    }

    func prompt(_ mode: DictationModeConfig) -> PromptTemplate {
        ModeResolver.prompt(for: mode, in: prompts)
    }

    var currentModeID: String { settings.currentModeID(in: modes) }

    // MARK: Hotkeys

    var routes: HotkeyRoutes {
        HotkeyRoutes.build(config: settings.hotkey, candidates: ModeHotkeyCandidate.list(modes: modes, prompts: prompts),
                           accessibilityTrusted: accessibilityTrusted)
    }

    /// Why the mode's hotkey does nothing (static checks first, then what macOS said).
    func problem(_ mode: DictationModeConfig, routes: HotkeyRoutes) -> ModeHotkeyProblem? {
        guard mode.isEnabled else { return nil }
        if let problem = routes.problems[mode.id] { return problem }
        if case .taken(let conflict) = hotkey.modeCombos[mode.id] { return .taken(conflict) }
        return nil
    }

    /// The main hotkey as it works right now (or as configured while it does not).
    var mainKeycaps: [String] {
        switch hotkey.active {
        case .single, .combo: return hotkey.active.keycaps
        case .unavailable: return accessibilityTrusted ? [settings.hotkey.trigger.shortName] : settings.hotkey.combo.keycaps
        }
    }

    /// The keys that start the mode: [⇧][右 ⌥], [⌥][⇧][Space] on the combination path, [⌃][⌥][M].
    func keycaps(_ shortcut: ModeShortcut) -> [String] {
        switch shortcut {
        case .withTrigger(let families):
            if case .combo(let combo) = hotkey.active { return families.reduce(combo) { $0.adding($1) }.keycaps }
            if !accessibilityTrusted, case .unavailable = hotkey.active {
                return families.reduce(settings.hotkey.combo) { $0.adding($1) }.keycaps
            }
            return shortcut.keycaps(mainHotkey: mainKeycaps)
        case .combination:
            return shortcut.keycaps(mainHotkey: [])
        }
    }

    /// "按住 ⇧ 再按 右 ⌥", "按 ⌃⌥ M".
    func sentence(_ shortcut: ModeShortcut) -> String {
        switch shortcut {
        case .withTrigger(let families):
            let held = KeyCombo.displayOrder.filter(families.contains).map(\.symbol).joined()
            return "按住 \(held) 再按 \(mainKeycaps.joined(separator: " "))"
        case .combination(let combo):
            return "按 \(combo.displayName)"
        }
    }

    // MARK: Tags

    struct Tag: Hashable {
        var symbol: String?
        var text: String
        /// Something is missing (a key): drawn in the accent colour.
        var isProblem = false
    }

    /// Engine; language (only when the mode sets it); AI; the prompt (only when it is not the
    /// mode's own: 「改寫」 using 「改寫」 says nothing); the translate language.
    func tags(_ mode: DictationModeConfig) -> [Tag] {
        let resolved = resolved(mode)
        let engineReady = settings.isReady(resolved.sttProvider)
        var tags = [Tag(symbol: engineReady ? "waveform" : "key.fill",
                        text: Self.shortEngineName(resolved.sttProvider, settings: settings), isProblem: !engineReady)]
        if let code = mode.recognition.language.customValue {
            tags.append(Tag(symbol: "globe", text: Self.languageName(code)))
        }
        guard let llm = resolved.llm, !(llmKeyMissing(llm) && !llm.required) else {
            // Plain dictation without a key for the AI step runs the basic cleanup, as before.
            tags.append(Tag(symbol: nil, text: "不用 AI"))
            return tags
        }
        if llmKeyMissing(llm) {
            tags.append(Tag(symbol: "key.fill", text: "需要 AI 的 key", isProblem: true))
        } else {
            tags.append(Tag(symbol: "sparkles", text: providerName(llm)))
        }
        let template = prompt(mode)
        if template.id != (mode.builtInID?.promptID ?? BuiltInPromptID.standard.rawValue) {
            tags.append(Tag(symbol: "text.quote", text: template.name))
        }
        if template.kind == .translate,
           let language = TranslateLanguage.all.first(where: { $0.promptName == resolved.translateTarget }) {
            tags.append(Tag(symbol: "arrow.right", text: language.displayName))
        }
        return tags
    }

    // MARK: Names

    /// The provider that runs: the first candidate with a key, else the first one.
    func providerName(_ llm: ResolvedLLM) -> String {
        let kind = llm.candidates.first { kind in kind.requiredKey.map(settings.hasKey) ?? false } ?? llm.candidates.first ?? .groq
        return kind.displayName
    }

    /// No candidate has a key: the AI step cannot run.
    func llmKeyMissing(_ llm: ResolvedLLM) -> Bool {
        !llm.candidates.contains { kind in kind.requiredKey.map(settings.hasKey) ?? false }
    }

    static func shortEngineName(_ kind: STTProviderKind, settings: MacSettings) -> String {
        switch kind {
        case .elevenLabsScribe: "Scribe v3"
        case .groqWhisperLarge: "Whisper"
        case .groqWhisperTurbo: "Whisper Turbo"
        case .custom: settings.customEngineName
        }
    }

    static func engineName(_ kind: STTProviderKind, settings: MacSettings) -> String {
        kind == .custom ? settings.customEngineName : kind.rowTitle
    }

    /// The languages a mode can pick (the engine's language hint).
    static let languageCodes = [ModeRecognition.automatic, "zh", "en", "ja", "ko"]

    static func languageName(_ code: String?) -> String {
        guard let code, code != ModeRecognition.automatic else { return "自動偵測" }
        return TranscriptLanguage(rawValue: code)?.displayName ?? code
    }

    static func onOff(_ value: Bool) -> String { value ? "開" : "關" }

    static func promptKindName(_ kind: PromptKind) -> String {
        switch kind {
        case .dictation: "整理文字"
        case .translate: "翻譯"
        case .rewrite: "改寫選取的文字"
        case .assistant: "回答問題"
        }
    }
}

/// The mode's SF Symbol in a soft circle (grey when the mode is off).
struct ModeIconBadge: View {
    let symbol: String
    var enabled = true
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(enabled ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.tertiary))
            .frame(width: size, height: size)
            .background(Circle().fill(enabled ? Theme.accent.opacity(0.13) : Color.primary.opacity(0.06)))
            .accessibilityHidden(true)
    }
}

/// A small grey capsule with an optional symbol.
struct ModeTagChip: View {
    let tag: ModeContext.Tag

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = tag.symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(tag.text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(tag.isProblem ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tag.isProblem ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.06)))
    }
}

/// 「預設」 next to the current mode's name.
struct DefaultModeBadge: View {
    var body: some View {
        Text("預設")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.22)))
            .accessibilityLabel("預設模式")
    }
}
