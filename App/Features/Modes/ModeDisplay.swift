import SwiftUI
import ScriberCore
import ScriberShared

/// What the iOS mode screens say about a mode — resolved against the current settings and keys —
/// in a few words (zh-Hant, Taiwan). Wording follows the Mac's modes page; only what iOS can do
/// is mentioned (no hotkeys, auto-apply, context, answer panel or auto-send).
@MainActor
struct ModeInfo {
    let settings: SettingsModel
    let modes: [DictationModeConfig]
    let prompts: [PromptTemplate]

    var defaults: ModeDefaults { settings.modeDefaults }

    func resolved(_ mode: DictationModeConfig) -> ResolvedModeConfig {
        ModeResolver.resolve(mode, prompts: prompts, defaults: defaults)
    }

    func prompt(_ mode: DictationModeConfig) -> PromptTemplate {
        ModeResolver.prompt(for: mode, in: prompts)
    }

    var defaultModeID: String { ModeResolver.mode(for: DictationRequest(), in: modes).id }

    /// The line under the mode's name, and a problem (missing key) to show instead in orange.
    func summary(_ mode: DictationModeConfig) -> (text: String, problem: String?) {
        let resolved = resolved(mode)
        let template = prompt(mode)
        var parts: [String] = []
        if !mode.isEnabled { parts.append(String(localized: "已停用")) }
        if template.kind == .rewrite { parts.append(String(localized: "選取文字時使用")) }
        if mode.recognition.engine.customValue != nil { parts.append(Self.engineName(resolved.sttProvider, settings: settings, short: true)) }
        if let code = mode.recognition.language.customValue { parts.append(Self.languageName(code)) }
        var problem: String?
        // A missing key of the global engine is a setup step (首頁), not this mode's problem.
        if mode.recognition.engine.customValue != nil, !settings.isReady(resolved.sttProvider) {
            problem = String(localized: "需要 \(resolved.sttProvider.requiredKey.vendor) 的 API key")
        }
        // Plain dictation without a key for its AI step runs the basic cleanup, as before modes.
        if let llm = resolved.llm, !(llmKeyMissing(llm) && !llm.required) {
            if llmKeyMissing(llm) {
                problem = problem ?? String(localized: "需要 AI 的 API key")
            } else {
                parts.append(providerName(llm))
            }
            if template.id != (mode.builtInID?.promptID ?? BuiltInPromptID.standard.rawValue) {
                parts.append(template.name)
            }
            if template.kind == .translate,
               let language = TranslateLanguage.all.first(where: { $0.promptName == resolved.translateTarget }) {
                parts.append(String(localized: "翻譯成\(language.displayName)"))
            }
        } else {
            parts.append(String(localized: "不用 AI"))
        }
        if mode.output == .copyOnly { parts.append(String(localized: "只複製")) }
        return (parts.joined(separator: "・"), problem)
    }

    /// The provider that runs: the first candidate with a key, else the first one.
    func providerName(_ llm: ResolvedLLM) -> String {
        let kind = llm.candidates.first { kind in kind.requiredKey.map(settings.hasKey) ?? false }
            ?? llm.candidates.first ?? .groq
        return kind.displayName
    }

    func llmKeyMissing(_ llm: ResolvedLLM) -> Bool {
        !llm.candidates.contains { kind in kind.requiredKey.map(settings.hasKey) ?? false }
    }

    // MARK: Names

    static func engineName(_ kind: STTProviderKind, settings: SettingsModel, short: Bool = false) -> String {
        if kind == .custom { return settings.customEngineName }
        return short ? kind.shortName : kind.rowTitle
    }

    /// The languages a mode can pick (the engine's language hint).
    static let languageCodes = [ModeRecognition.automatic, "zh", "en", "ja", "ko"]

    static func languageName(_ code: String?) -> String {
        guard let code, code != ModeRecognition.automatic else { return String(localized: "自動偵測") }
        return TranscriptLanguage(rawValue: code)?.displayName ?? code
    }

    static func onOff(_ value: Bool) -> String { value ? String(localized: "開") : String(localized: "關") }

    static func promptKindName(_ kind: PromptKind) -> String {
        switch kind {
        case .dictation: String(localized: "整理文字")
        case .translate: String(localized: "翻譯")
        case .rewrite: String(localized: "改寫選取的文字")
        case .assistant: String(localized: "回答問題")
        }
    }

    /// 「新模式」, 「新模式 2」…
    static func newName(in modes: [DictationModeConfig]) -> String {
        let names = Set(modes.map(\.name))
        let base = String(localized: "新模式")
        if !names.contains(base) { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Longest mode name (same as the Mac).
    static let maxNameLength = 20
}

/// The mode's SF Symbol in a soft grey circle: monochrome like the keyboard, the accent colour is
/// kept for primary actions.
struct ModeIcon: View {
    let symbol: String
    var enabled = true
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(.tertiarySystemFill)))
            .accessibilityHidden(true)
    }
}

/// 「預設」 next to the default mode's name.
struct DefaultModeBadge: View {
    var body: some View {
        Text("預設")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.22)))
            .accessibilityLabel("預設模式")
    }
}
