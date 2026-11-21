import Foundation
import ScriberShared

// User-facing names for the contract enums (Mac copy of the iOS app's DisplayNames; the shared
// screens move to `Shared/` in M2). zh-Hant (Taiwan).

extension STTProviderKind {
    static let builtIn: [STTProviderKind] = [.elevenLabsScribe, .groqWhisperLarge, .groqWhisperTurbo]

    var tag: String {
        switch self {
        case .elevenLabsScribe: "ElevenLabs・最準"
        case .groqWhisperLarge: "Groq・快又便宜"
        case .groqWhisperTurbo: "Groq・最快"
        case .custom: "OpenAI 相容"
        }
    }

    /// Row title in Settings.
    var rowTitle: String {
        switch self {
        case .elevenLabsScribe: "Scribe v3"
        case .groqWhisperLarge: "Whisper Large v3"
        case .groqWhisperTurbo: "Whisper Large v3 Turbo"
        case .custom: "自訂"
        }
    }

    /// Longer trade-off, shown behind "?".
    var tradeoff: String {
        switch self {
        case .elevenLabsScribe: "專有名詞和中英夾雜最穩，價格較高。"
        case .groqWhisperLarge: "很快又便宜，偶爾出現簡體字，會自動轉成繁體。"
        case .groqWhisperTurbo: "最快、最便宜，準確度稍低一點。"
        case .custom: "任何 OpenAI 相容的語音轉文字服務，自己填網址、模型和 key。"
        }
    }

    var requiredKey: APIKeyKind {
        switch self {
        case .elevenLabsScribe: .elevenLabs
        case .groqWhisperLarge, .groqWhisperTurbo: .groq
        case .custom: .custom
        }
    }
}

extension PolishProviderKind {
    var displayName: String {
        switch self {
        case .off: "關閉"
        case .groq: "Groq"
        case .anthropic: "Claude Haiku"
        }
    }

    var tag: String {
        switch self {
        case .off: "最快"
        case .groq: "快"
        case .anthropic: "Anthropic・語感最好"
        }
    }

    /// Shown behind "?".
    var detail: String {
        switch self {
        case .off: "只做基本整理：去掉贅字、轉成繁體。"
        case .groq: "很快，和 Whisper 共用同一把 Groq key。"
        case .anthropic: "中文語感最好，稍慢一點。"
        }
    }

    var requiredKey: APIKeyKind? {
        switch self {
        case .off: nil
        case .groq: .groq
        case .anthropic: .anthropic
        }
    }
}

extension APIKeyKind {
    /// The service's name. For the custom engine use `MacSettings.vendor(_:)`, which knows the
    /// name the user gave it.
    var vendor: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .groq: "Groq"
        case .anthropic: "Anthropic"
        case .custom: "自訂引擎"
        }
    }

    var usage: String {
        switch self {
        case .elevenLabs: "語音辨識（Scribe v3）"
        case .groq: "語音辨識（Whisper）、AI 潤飾、翻譯"
        case .anthropic: "AI 潤飾、翻譯（Claude Haiku）"
        case .custom: "自訂語音辨識引擎"
        }
    }

    var consoleURL: URL? {
        switch self {
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .custom: nil
        }
    }

    /// The engine to switch to when this is the first speech key the user adds.
    var defaultSTTProvider: STTProviderKind? {
        switch self {
        case .elevenLabs: .elevenLabsScribe
        case .groq: .groqWhisperLarge
        case .anthropic: nil
        case .custom: .custom
        }
    }
}

extension DictationMode {
    var displayName: String {
        switch self {
        case .dictate: "聽寫"
        case .translate: "翻譯"
        case .edit: "說話改字"
        }
    }

    var symbol: String {
        switch self {
        case .dictate: "mic"
        case .translate: "translate"
        case .edit: "wand.and.stars"
        }
    }
}
