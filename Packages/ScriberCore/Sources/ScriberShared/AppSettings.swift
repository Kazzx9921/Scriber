import Foundation

// CONTRACT FILE — plain UserDefaults-backed settings in the App Group suite, readable from both processes.

public enum STTProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case elevenLabsScribe
    case groqWhisperLarge
    case groqWhisperTurbo
    /// A user-defined OpenAI-compatible transcription endpoint (see `customSTT…` settings).
    case custom
    public var id: String { rawValue }
}

public enum PolishProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// No LLM. Only rule-based cleanup + zh-TW conversion. Fastest.
    case off
    case groq
    case anthropic
    public var id: String { rawValue }
}

public enum APIKeyKind: String, CaseIterable, Sendable {
    case elevenLabs, groq, anthropic
    /// Key for the user-defined STT endpoint.
    case custom
}

/// How the app stays reachable between dictations (so the keyboard does not have to open it every time).
public enum StandbyMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Release everything as soon as a dictation finishes. Every dictation opens the app once.
    case off
    /// Keep the audio engine running but mute the input (`AVAudioApplication.setInputMuted`) while idle.
    case mutedInput
    /// Stop the input completely while idle; an output-only (silent) engine keeps the process alive.
    case outputOnly
    public var id: String { rawValue }
}

/// Which app a setting's default is for, where the two differ (`AppSettings.realtimeDefault`).
public enum SettingsPlatform: String, Sendable {
    case iOS, macOS

    public static var current: SettingsPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

public struct AppSettings: Sendable {
    public static let shared = AppSettings()
    private var d: UserDefaults { AppGroup.defaults }
    public init() {}

    public var hasCompletedOnboarding: Bool {
        get { d.bool(forKey: "hasCompletedOnboarding") }
        nonmutating set { d.set(newValue, forKey: "hasCompletedOnboarding") }
    }
    public var sttProvider: STTProviderKind {
        get { STTProviderKind(rawValue: d.string(forKey: "sttProvider") ?? "") ?? .elevenLabsScribe }
        nonmutating set { d.set(newValue.rawValue, forKey: "sttProvider") }
    }
    public var polishProvider: PolishProviderKind {
        get { PolishProviderKind(rawValue: d.string(forKey: "polishProvider") ?? "") ?? .off }
        nonmutating set { d.set(newValue.rawValue, forKey: "polishProvider") }
    }
    /// How long the background listening session stays alive after it is started.
    public var sessionMinutes: Int {
        get { let v = d.integer(forKey: "sessionMinutes"); return v == 0 ? 10 : v }
        nonmutating set { d.set(newValue, forKey: "sessionMinutes") }
    }
    /// "中文 English 中文" vs "中文English中文".
    public var spaceBetweenCJKAndLatin: Bool {
        get { d.object(forKey: "spaceBetweenCJKAndLatin") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "spaceBetweenCJKAndLatin") }
    }
    /// Always convert output to Traditional Chinese (Taiwan). On by default.
    public var forceTraditional: Bool {
        get { d.object(forKey: "forceTraditional") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "forceTraditional") }
    }
    /// BCP-47-ish display name used in the translate prompt, e.g. "English".
    public var translateTarget: String {
        get { d.string(forKey: "translateTarget") ?? "English" }
        nonmutating set { d.set(newValue, forKey: "translateTarget") }
    }
    // MARK: Custom STT endpoint (OpenAI-compatible `/audio/transcriptions`)

    /// Base URL, e.g. "https://api.openai.com/v1". The provider appends "/audio/transcriptions".
    public var customSTTBaseURL: String {
        get { d.string(forKey: "customSTTBaseURL") ?? "" }
        nonmutating set { d.set(newValue, forKey: "customSTTBaseURL") }
    }
    /// Model id sent as `model`, e.g. "whisper-1".
    public var customSTTModel: String {
        get { d.string(forKey: "customSTTModel") ?? "" }
        nonmutating set { d.set(newValue, forKey: "customSTTModel") }
    }
    /// Name shown in the UI for the custom engine.
    public var customSTTName: String {
        get { d.string(forKey: "customSTTName") ?? "" }
        nonmutating set { d.set(newValue, forKey: "customSTTName") }
    }

    // MARK: Real-time transcription

    /// Stream audio to a real-time engine while speaking (ElevenLabs Scribe v3 Live). Only applies
    /// when the engine supports it; falls back to the normal upload-after-speaking path otherwise.
    /// macOS (「即時顯示文字」): the HUD shows the text as it is recognized; off unless turned on.
    /// iOS (「邊講邊辨識」): nothing is shown, the text is just ready sooner after stopping; on
    /// unless turned off. Each device keeps its own value (the App Group is per device).
    public var realtimeEnabled: Bool {
        get { Self.realtimeEnabled(in: d) }
        nonmutating set { d.set(newValue, forKey: Self.realtimeEnabledKey) }
    }

    static let realtimeEnabledKey = "realtimeEnabled"

    /// The value stored in `defaults`, or `realtimeDefault(for:)` when there is none (every iOS
    /// install before this setting existed, and a Mac that never touched the switch).
    public static func realtimeEnabled(in defaults: UserDefaults, platform: SettingsPlatform = .current) -> Bool {
        defaults.object(forKey: realtimeEnabledKey) as? Bool ?? realtimeDefault(for: platform)
    }

    /// iOS: on (a speed-up only). macOS: off, as it has always been.
    public static func realtimeDefault(for platform: SettingsPlatform) -> Bool {
        switch platform {
        case .iOS: return true
        case .macOS: return false
        }
    }

    // MARK: Experimental (being verified on device)

    public var standbyMode: StandbyMode {
        get { StandbyMode(rawValue: d.string(forKey: "standbyMode") ?? "") ?? .mutedInput }
        nonmutating set { d.set(newValue.rawValue, forKey: "standbyMode") }
    }
    /// How long standby lasts after the last dictation.
    public var standbyMinutes: Int {
        get { let v = d.integer(forKey: "standbyMinutes"); return v == 0 ? 10 : v }
        nonmutating set { d.set(newValue, forKey: "standbyMinutes") }
    }
    /// Record inside the keyboard itself (hidden WKWebView + getUserMedia, iOS 26+) so no app switch is needed.
    public var inKeyboardCapture: Bool {
        get { d.object(forKey: "inKeyboardCapture") as? Bool ?? false }
        nonmutating set { d.set(newValue, forKey: "inKeyboardCapture") }
    }
    /// After the keyboard opens the app, try to send the user back to the app they came from.
    public var autoReturn: Bool {
        get { d.object(forKey: "autoReturn") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "autoReturn") }
    }

    public var saveHistory: Bool {
        get { d.object(forKey: "saveHistory") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "saveHistory") }
    }
    public var hapticsEnabled: Bool {
        get { d.object(forKey: "hapticsEnabled") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "hapticsEnabled") }
    }
}
