import Foundation
import ScriberShared

// User-facing names and one-liners for the contract enums. zh-Hant (Taiwan) is the development language.

extension STTProviderKind {
    /// The engines offered by name; `.custom` is listed separately because it needs setting up.
    static let builtIn: [STTProviderKind] = [.elevenLabsScribe, .groqWhisperLarge, .groqWhisperTurbo]

    /// Name of the user's custom engine, or "自訂" before it has one.
    static var customName: String {
        let name = AppSettings.shared.customSTTName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "自訂") : name
    }

    var displayName: String {
        switch self {
        case .elevenLabsScribe: "ElevenLabs Scribe v3"
        case .groqWhisperLarge: "Groq Whisper Large v3"
        case .groqWhisperTurbo: "Groq Whisper Large v3 Turbo"
        case .custom: Self.customName
        }
    }

    /// Fits a menu or a one-line caption.
    var shortName: String {
        switch self {
        case .elevenLabsScribe: "Scribe v3"
        case .groqWhisperLarge: "Whisper"
        case .groqWhisperTurbo: "Turbo"
        case .custom: Self.customName
        }
    }

    /// Settings row title (the vendor goes into `tag`).
    var rowTitle: String {
        switch self {
        case .elevenLabsScribe: "Scribe v3"
        case .groqWhisperLarge: "Whisper Large v3"
        case .groqWhisperTurbo: "Whisper Large v3 Turbo"
        case .custom: Self.customName
        }
    }

    /// A few words under the row title.
    var tag: String {
        switch self {
        case .elevenLabsScribe: String(localized: "ElevenLabs・最準")
        case .groqWhisperLarge: String(localized: "Groq・快又便宜")
        case .groqWhisperTurbo: String(localized: "Groq・最快")
        case .custom: String(localized: "OpenAI 相容")
        }
    }

    /// Longer trade-off, shown on demand behind "?".
    var tradeoff: String {
        switch self {
        case .elevenLabsScribe: String(localized: "專有名詞和中英夾雜最穩，價格較高。")
        case .groqWhisperLarge: String(localized: "很快又便宜，偶爾出現簡體字，會自動轉成繁體。")
        case .groqWhisperTurbo: String(localized: "最快、最便宜，準確度稍低一點。")
        case .custom: String(localized: "任何 OpenAI 相容的語音轉文字服務，自己填網址、模型和 key。")
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
        case .off: String(localized: "關閉")
        case .groq: "Groq"
        case .anthropic: "Claude Haiku"
        }
    }

    var shortName: String {
        switch self {
        case .off: String(localized: "不潤飾")
        case .groq: "Groq"
        case .anthropic: "Haiku"
        }
    }

    var tag: String {
        switch self {
        case .off: String(localized: "最快")
        case .groq: String(localized: "快")
        case .anthropic: String(localized: "Anthropic・語感最好")
        }
    }

    var detail: String {
        switch self {
        case .off: String(localized: "只做基本整理：去掉贅字、轉成繁體。")
        case .groq: String(localized: "很快，和 Whisper 共用同一把 Groq key。")
        case .anthropic: String(localized: "中文語感最好，稍慢一點。")
        }
    }

    /// nil when no key is needed.
    var requiredKey: APIKeyKind? {
        switch self {
        case .off: nil
        case .groq: .groq
        case .anthropic: .anthropic
        }
    }
}

extension APIKeyKind {
    var vendor: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .groq: "Groq"
        case .anthropic: "Anthropic"
        case .custom: STTProviderKind.customName
        }
    }

    var usage: String {
        switch self {
        case .elevenLabs: String(localized: "語音辨識（Scribe v3）")
        case .groq: String(localized: "語音辨識（Whisper）與 AI 潤飾")
        case .anthropic: String(localized: "AI 潤飾（Claude Haiku）")
        case .custom: String(localized: "自訂語音辨識引擎")
        }
    }

    /// Where to create a key; nil for the custom engine (the user knows their own service).
    var consoleURL: URL? {
        switch self {
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .custom: nil
        }
    }

    /// True if this key alone is enough to transcribe speech.
    var canTranscribe: Bool { self != .anthropic }

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
        case .dictate: String(localized: "聽寫")
        case .translate: String(localized: "翻譯")
        case .edit: String(localized: "說話改字")
        }
    }

    var symbol: String {
        switch self {
        case .dictate: "mic"
        case .translate: "translate"
        case .edit: "pencil.and.scribble"
        }
    }
}

extension StandbyMode {
    var displayName: String {
        switch self {
        case .off: String(localized: "講完即關")
        case .mutedInput: String(localized: "靜音待命")
        case .outputOnly: String(localized: "輸出待命")
        }
    }

    /// A few words under the option.
    var tag: String {
        switch self {
        case .off: String(localized: "每次說話都會跳到 Scriber")
        case .mutedInput: String(localized: "背景待命，麥克風靜音")
        case .outputOnly: String(localized: "背景待命，麥克風關閉")
        }
    }

    /// Does the app open every time, and is the orange microphone light expected. Shown behind "?".
    var tradeoff: String {
        switch self {
        case .off:
            String(localized: "每次說話都會先跳到 Scriber 一下。講完麥克風馬上關，橘色麥克風燈只在錄音時亮。")
        case .mutedInput:
            String(localized: "講完後在背景待命，下次不用跳到 Scriber。麥克風沒關只是靜音，橘燈應該會熄（還在實測）。")
        case .outputOnly:
            String(localized: "講完後完全關掉麥克風，橘燈會熄，下次也不用跳過去。但 iOS 可能不准背景重開麥克風，那時會請你再點一次。")
        }
    }
}

enum Format {
    /// 820 → "0.82 秒"
    static func seconds(millis: Int) -> String {
        String(format: String(localized: "%.2f 秒"), Double(millis) / 1000)
    }

    /// A duration as number/unit pairs for display, e.g. 8040 s → [("2", "小時"), ("14", "分")].
    /// Under a minute shows seconds; under ten minutes shows minutes and seconds.
    static func durationParts(seconds: Double) -> [(value: String, unit: String)] {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        let h = String(localized: "小時"), m = String(localized: "分"), s = String(localized: "秒")
        if hours > 0 {
            return minutes > 0 && hours < 100 ? [("\(hours)", h), ("\(minutes)", m)] : [("\(hours)", h)]
        }
        if minutes >= 10 { return [("\(minutes)", m)] }
        if minutes > 0 { return secs > 0 ? [("\(minutes)", m), ("\(secs)", s)] : [("\(minutes)", m)] }
        return [("\(secs)", s)]
    }

    /// "2 小時 14 分" in one string (VoiceOver, captions).
    static func duration(seconds: Double) -> String {
        durationParts(seconds: seconds).map { "\($0.value) \($0.unit)" }.joined(separator: " ")
    }
}
