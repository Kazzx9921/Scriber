import Foundation

// CONTRACT FILE — shared by the iOS app, the keyboard and the Mac app. See docs/PRD-模式.md.
//
// A mode bundles "which engine, whether the AI runs and with which prompt, what context it gets,
// and what happens to the result". This file is plain data; storage is `ModeStore`, resolution
// against the global settings is `ModeResolver` (both in ScriberCore).
//
// Decoding is tolerant on purpose: files are written by other app versions (the keyboard and the
// app update together, but a Mac may run an older build against a newer file and vice versa).
// Missing fields take their defaults, unknown fields are ignored (and dropped on the next write),
// and an enum value this version does not know falls back to a safe default instead of failing
// the whole mode.

// MARK: - Follow the default, or override

/// A setting a mode either takes from the global defaults (設定) or sets itself.
///
/// Encoded as the bare value, or `null` for "follow the default". Decoding never fails: a missing
/// key, `null`, or a value this version cannot read (e.g. an engine added later) all mean
/// "follow the default".
public enum ModeOverride<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case followDefault
    case custom(Value)

    /// The mode's own value, or `fallback` when it follows the default.
    public func resolved(_ fallback: Value) -> Value {
        switch self {
        case .followDefault: return fallback
        case .custom(let value): return value
        }
    }

    public var customValue: Value? {
        if case .custom(let value) = self { return value }
        return nil
    }

    public var followsDefault: Bool { customValue == nil }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .followDefault
        } else if let value = try? container.decode(Value.self) {
            self = .custom(value)
        } else {
            self = .followDefault
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .followDefault: try container.encodeNil()
        case .custom(let value): try container.encode(value)
        }
    }
}

// MARK: - Enums

/// What the AI is asked to do with the transcript. Decides the safety wrapper the code puts around
/// the prompt (see `PolishPrompt` in ScriberCore), which the user-editable prompt text cannot change.
public enum PromptKind: String, Codable, CaseIterable, Sendable {
    /// The transcript is the speaker's own words to clean up or reformat (預設, Email, 條列重點,
    /// 會議紀錄). It is data, never answered or executed.
    case dictation
    /// Translate the transcript into the target language (`{{language}}`). Never answered.
    case translate
    /// The transcript is an instruction to rewrite the selected text (改寫 / 說話改字). Without a
    /// selection the mode behaves like plain dictation.
    case rewrite
    /// The transcript is a question and the AI answers it (助理). The only kind that answers.
    case assistant

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Unknown kinds become dictation: the safest wrapper (never answers).
        self = PromptKind(rawValue: raw) ?? .dictation
    }
}

/// What happens to the finished text (PRD §4). M1 stores it and reports it in `PipelineResult`;
/// the apps act on it from M3.
public enum ModeOutput: String, Codable, CaseIterable, Sendable {
    /// Type it at the cursor (what dictation does today).
    case paste
    /// Replace the selected text (改寫). Without a selection it is the same as `paste`.
    case replaceSelection
    /// Show the AI's answer in a floating panel instead of typing it.
    case answer
    /// Put it on the clipboard only.
    case copyOnly

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ModeOutput(rawValue: raw) ?? .paste
    }
}

/// Key pressed after pasting (PRD §7.5). Default `none`.
public enum ModeAutoSend: String, Codable, CaseIterable, Sendable {
    case none
    case returnKey = "return"
    case commandReturn = "cmdReturn"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ModeAutoSend(rawValue: raw) ?? .none
    }
}

// MARK: - Groups

/// How a mode is started (PRD §2 觸發, §7.2, §7.3). Stored only in M1: nothing acts on it yet.
public struct ModeTrigger: Codable, Hashable, Sendable {
    /// This mode's own hotkey, if any.
    public var hotkey: ModeHotkey?
    /// macOS: use this mode when one of these apps is in front (bundle identifiers).
    public var appBundleIDs: [String]
    /// macOS, later phase: URL patterns of the browser's current page.
    public var websites: [String]

    public init(hotkey: ModeHotkey? = nil, appBundleIDs: [String] = [], websites: [String] = []) {
        self.hotkey = hotkey; self.appBundleIDs = appBundleIDs; self.websites = websites
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = (try? c.decodeIfPresent(ModeHotkey.self, forKey: .hotkey)) ?? nil
        appBundleIDs = (try? c.decodeIfPresent([String].self, forKey: .appBundleIDs)) ?? []
        websites = (try? c.decodeIfPresent([String].self, forKey: .websites)) ?? []
    }
}

/// A hotkey description, as plain data (the Mac's hotkey types are app-side).
public struct ModeHotkey: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Hold `modifiers` together with the main trigger key (the pre-modes 說話改字 = ⇧ and
        /// 翻譯 = ⌃ variants).
        case withMainTrigger
        /// A dedicated key combination: `keyCode` with `modifiers`.
        case combination
    }

    public var kind: Kind
    /// Modifier family names: "shift", "control", "option", "command".
    public var modifiers: [String]
    /// `.combination` only: the virtual key code, and the key as printed when it was chosen.
    public var keyCode: Int?
    public var keyLabel: String?

    public init(kind: Kind, modifiers: [String], keyCode: Int? = nil, keyLabel: String? = nil) {
        self.kind = kind; self.modifiers = modifiers; self.keyCode = keyCode; self.keyLabel = keyLabel
    }

    /// The modifier names `ModeHotkey` understands.
    public static let modifierNames: Set<String> = ["shift", "control", "option", "command"]

    /// "Hold `modifier` with the trigger"; nil for "none" or a name this version does not know.
    public static func withMainTrigger(_ modifier: String) -> ModeHotkey? {
        guard modifierNames.contains(modifier) else { return nil }
        return ModeHotkey(kind: .withMainTrigger, modifiers: [modifier])
    }
}

/// 辨識: engine, language, real-time text.
public struct ModeRecognition: Codable, Hashable, Sendable {
    public var engine: ModeOverride<STTProviderKind>
    /// A language code for the engine ("zh", "en", …) or `ModeRecognition.automatic`.
    public var language: ModeOverride<String>
    /// Show text while speaking (only ElevenLabs Scribe can).
    public var realtime: ModeOverride<Bool>

    /// `language` value meaning "let the engine detect it".
    public static let automatic = "auto"

    public init(engine: ModeOverride<STTProviderKind> = .followDefault, language: ModeOverride<String> = .followDefault,
                realtime: ModeOverride<Bool> = .followDefault) {
        self.engine = engine; self.language = language; self.realtime = realtime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = c.tolerant(.engine)
        language = c.tolerant(.language)
        realtime = c.tolerant(.realtime)
    }
}

/// 文字格式: each one follows the global setting or is set for this mode.
public struct ModeTextFormat: Codable, Hashable, Sendable {
    public var forceTraditional: ModeOverride<Bool>
    public var spaceBetweenCJKAndLatin: ModeOverride<Bool>
    public var punctuationRule: ModeOverride<PunctuationRule>
    public var punctuationLimit: ModeOverride<Int>

    public init(forceTraditional: ModeOverride<Bool> = .followDefault,
                spaceBetweenCJKAndLatin: ModeOverride<Bool> = .followDefault,
                punctuationRule: ModeOverride<PunctuationRule> = .followDefault,
                punctuationLimit: ModeOverride<Int> = .followDefault) {
        self.forceTraditional = forceTraditional; self.spaceBetweenCJKAndLatin = spaceBetweenCJKAndLatin
        self.punctuationRule = punctuationRule; self.punctuationLimit = punctuationLimit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forceTraditional = c.tolerant(.forceTraditional)
        spaceBetweenCJKAndLatin = c.tolerant(.spaceBetweenCJKAndLatin)
        punctuationRule = c.tolerant(.punctuationRule)
        punctuationLimit = c.tolerant(.punctuationLimit)
    }
}

/// AI 處理.
public struct ModeAI: Codable, Hashable, Sendable {
    /// Whether the LLM runs. `.followDefault`: on when the global 「AI 潤飾」 setting picks a
    /// provider (exactly what plain dictation does today). Prompts of kind translate / rewrite /
    /// assistant always need the LLM, whatever this says.
    public var enabled: ModeOverride<Bool>
    /// Which LLM. `.followDefault`: the global AI 潤飾 provider; when that is off, the first one
    /// with a key (Groq, then Anthropic). `.custom(.off)` means the same as `.followDefault`.
    public var provider: ModeOverride<PolishProviderKind>
    /// Model id for the provider; nil = the provider's built-in model. Stored only in M1.
    public var model: String?
    /// Prompt from the prompt library; nil (or an id that no longer exists) = the mode's
    /// built-in prompt (預設 for modes the user made).
    public var promptID: String?
    /// Translate target as a `TranslateLanguage` id ("en", "ja"…) for `{{language}}`.
    /// `.followDefault`: the global translate language (the keyboard's quick-language key).
    public var translateLanguageID: ModeOverride<String>

    public init(enabled: ModeOverride<Bool> = .followDefault, provider: ModeOverride<PolishProviderKind> = .followDefault,
                model: String? = nil, promptID: String? = nil, translateLanguageID: ModeOverride<String> = .followDefault) {
        self.enabled = enabled; self.provider = provider; self.model = model; self.promptID = promptID
        self.translateLanguageID = translateLanguageID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.tolerant(.enabled)
        provider = c.tolerant(.provider)
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        promptID = (try? c.decodeIfPresent(String.self, forKey: .promptID)) ?? nil
        translateLanguageID = c.tolerant(.translateLanguageID)
    }
}

/// 情境感知 (PRD §7.6): what is sent to the AI besides the transcript. Off by default; for prompts
/// of kind rewrite the selected text is always sent (it is what gets rewritten).
public struct ModeContextFlags: Codable, Hashable, Sendable {
    public var selectedText: Bool
    public var clipboard: Bool
    public var appName: Bool

    public init(selectedText: Bool = false, clipboard: Bool = false, appName: Bool = false) {
        self.selectedText = selectedText; self.clipboard = clipboard; self.appName = appName
    }

    public static let none = ModeContextFlags()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedText = (try? c.decodeIfPresent(Bool.self, forKey: .selectedText)) ?? false
        clipboard = (try? c.decodeIfPresent(Bool.self, forKey: .clipboard)) ?? false
        appName = (try? c.decodeIfPresent(Bool.self, forKey: .appName)) ?? false
    }
}

// MARK: - The mode

public struct DictationModeConfig: Codable, Identifiable, Hashable, Sendable {
    /// Schema version written with every mode.
    public static let currentVersion = 1

    public var version: Int
    /// Stable. The six shipped modes use `BuiltInModeID` raw values; modes the user makes get a UUID.
    public var id: String
    public var name: String
    /// SF Symbol name.
    public var icon: String
    public var isEnabled: Bool
    /// The mode the normal hotkey / mic button uses. Exactly one mode is the default (`ModeStore`).
    public var isDefault: Bool
    public var trigger: ModeTrigger
    public var recognition: ModeRecognition
    public var textFormat: ModeTextFormat
    public var ai: ModeAI
    public var context: ModeContextFlags
    public var output: ModeOutput
    public var autoSend: ModeAutoSend

    public init(id: String = UUID().uuidString, name: String, icon: String = "mic", isEnabled: Bool = true,
                isDefault: Bool = false, trigger: ModeTrigger = ModeTrigger(), recognition: ModeRecognition = ModeRecognition(),
                textFormat: ModeTextFormat = ModeTextFormat(), ai: ModeAI = ModeAI(), context: ModeContextFlags = .none,
                output: ModeOutput = .paste, autoSend: ModeAutoSend = .none) {
        self.version = Self.currentVersion
        self.id = id; self.name = name; self.icon = icon; self.isEnabled = isEnabled; self.isDefault = isDefault
        self.trigger = trigger; self.recognition = recognition; self.textFormat = textFormat; self.ai = ai
        self.context = context; self.output = output; self.autoSend = autoSend
    }

    public var builtInID: BuiltInModeID? { BuiltInModeID(rawValue: id) }
    public var isBuiltIn: Bool { builtInID != nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The id is the only field without a default: a mode without one cannot be referenced.
        id = try c.decode(String.self, forKey: .id)
        let factory = BuiltInModeID(rawValue: id).map(DictationModeConfig.builtIn)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? factory?.name ?? ""
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? factory?.icon ?? "mic"
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        isDefault = (try? c.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? false
        trigger = (try? c.decodeIfPresent(ModeTrigger.self, forKey: .trigger)) ?? factory?.trigger ?? ModeTrigger()
        recognition = (try? c.decodeIfPresent(ModeRecognition.self, forKey: .recognition)) ?? ModeRecognition()
        textFormat = (try? c.decodeIfPresent(ModeTextFormat.self, forKey: .textFormat)) ?? ModeTextFormat()
        ai = (try? c.decodeIfPresent(ModeAI.self, forKey: .ai)) ?? factory?.ai ?? ModeAI()
        context = (try? c.decodeIfPresent(ModeContextFlags.self, forKey: .context)) ?? factory?.context ?? .none
        output = (try? c.decodeIfPresent(ModeOutput.self, forKey: .output)) ?? factory?.output ?? .paste
        autoSend = (try? c.decodeIfPresent(ModeAutoSend.self, forKey: .autoSend)) ?? .none
    }
}

// MARK: - Built-in modes (PRD §3)

/// Stable ids of the shipped modes, in their shipped order.
public enum BuiltInModeID: String, CaseIterable, Sendable {
    case dictate = "builtin.dictate"
    case polish = "builtin.polish"
    case translate = "builtin.translate"
    case rewrite = "builtin.rewrite"
    case email = "builtin.email"
    case assistant = "builtin.assistant"

    /// The built-in mode the pre-modes request enum maps to. `.dictate` has none: it means
    /// "the default mode" (聽寫 unless the user picks another one).
    public static func forLegacy(_ mode: DictationMode) -> BuiltInModeID? {
        switch mode {
        case .dictate: return nil
        case .translate: return .translate
        case .edit: return .rewrite
        }
    }

    /// The prompt-library id this mode uses out of the box.
    public var promptID: String {
        switch self {
        case .dictate, .polish: return BuiltInPromptID.standard.rawValue
        case .translate: return BuiltInPromptID.translate.rawValue
        case .rewrite: return BuiltInPromptID.rewrite.rawValue
        case .email: return BuiltInPromptID.email.rawValue
        case .assistant: return BuiltInPromptID.assistant.rawValue
        }
    }
}

/// Stable ids of the shipped prompts (PRD §5).
public enum BuiltInPromptID: String, CaseIterable, Sendable {
    /// 預設: remove fillers, fix punctuation.
    case standard = "builtin.prompt.default"
    case email = "builtin.prompt.email"
    case rewrite = "builtin.prompt.rewrite"
    case translate = "builtin.prompt.translate"
    case assistant = "builtin.prompt.assistant"
    case bullets = "builtin.prompt.bullets"
    case meeting = "builtin.prompt.meeting"
}

public extension DictationModeConfig {
    /// The shipped configuration of a built-in mode (also what 「還原預設」 restores).
    static func builtIn(_ id: BuiltInModeID) -> DictationModeConfig {
        switch id {
        case .dictate:
            // AI follows the global 「AI 潤飾」 switch: polish on → plain dictation is polished,
            // exactly as before modes existed.
            return DictationModeConfig(id: id.rawValue, name: "聽寫", icon: "mic", isDefault: true,
                                       ai: ModeAI(enabled: .followDefault, promptID: id.promptID))
        case .polish:
            return DictationModeConfig(id: id.rawValue, name: "潤飾", icon: "sparkles",
                                       ai: ModeAI(enabled: .custom(true), promptID: id.promptID))
        case .translate:
            return DictationModeConfig(id: id.rawValue, name: "翻譯", icon: "translate",
                                       trigger: ModeTrigger(hotkey: .withMainTrigger("control")),
                                       ai: ModeAI(enabled: .custom(true), promptID: id.promptID))
        case .rewrite:
            return DictationModeConfig(id: id.rawValue, name: "改寫", icon: "pencil.and.scribble",
                                       trigger: ModeTrigger(hotkey: .withMainTrigger("shift")),
                                       ai: ModeAI(enabled: .custom(true), promptID: id.promptID),
                                       context: ModeContextFlags(selectedText: true), output: .replaceSelection)
        case .email:
            return DictationModeConfig(id: id.rawValue, name: "Email", icon: "envelope",
                                       trigger: ModeTrigger(appBundleIDs: ["com.apple.mail"]),
                                       ai: ModeAI(enabled: .custom(true), promptID: id.promptID))
        case .assistant:
            return DictationModeConfig(id: id.rawValue, name: "助理", icon: "bubble.left.and.text.bubble.right",
                                       ai: ModeAI(enabled: .custom(true), promptID: id.promptID), output: .answer)
        }
    }

    /// All shipped modes in their shipped order.
    static var builtIns: [DictationModeConfig] { BuiltInModeID.allCases.map(builtIn) }
}

// MARK: - Helpers

extension KeyedDecodingContainer {
    /// Missing key, null or an unreadable value → follow the default.
    func tolerant<Value>(_ key: Key) -> ModeOverride<Value> {
        ((try? decodeIfPresent(ModeOverride<Value>.self, forKey: key)) ?? nil) ?? .followDefault
    }
}
