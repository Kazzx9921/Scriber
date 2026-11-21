import Foundation
import ScriberShared

enum GroqAPI {
    /// OpenAI-compatible base. Docs: https://console.groq.com/docs/api-reference
    static let baseURL = URL(string: "https://api.groq.com/openai/v1")!
}

/// Groq-hosted Whisper (OpenAI-compatible `/audio/transcriptions`).
///
/// Docs: https://console.groq.com/docs/speech-to-text
///       https://console.groq.com/docs/models
public struct GroqWhisperSTT: STTProvider {
    public enum Model: String, Sendable {
        case largeV3 = "whisper-large-v3"
        case largeV3Turbo = "whisper-large-v3-turbo"
    }

    let apiKey: String
    let model: Model
    let session: URLSession
    let timeout: TimeInterval

    public init(apiKey: String, model: Model, timeout: TimeInterval = 240) {
        self.init(apiKey: apiKey, model: model, timeout: timeout, session: ProviderHTTP.defaultSession)
    }

    init(apiKey: String, model: Model, timeout: TimeInterval = 240, session: URLSession) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    public func transcribe(audioFile: URL, options: STTOptions) async throws -> String {
        try await client.transcribe(audioFile: audioFile, options: options)
    }

    func makeRequest(audio: Data, filename: String, mimeType: String,
                     options: STTOptions, prompt: String) -> URLRequest {
        client.makeRequest(audio: audio, filename: filename, mimeType: mimeType, options: options, prompt: prompt)
    }

    /// Groq's endpoint is the OpenAI-compatible one.
    private var client: OpenAITranscription {
        OpenAITranscription(endpoint: GroqAPI.baseURL.appendingPathComponent("audio/transcriptions"),
                            model: model.rawValue, apiKey: apiKey, timeout: timeout, session: session,
                            vendor: "groq")
    }
}

/// Builds Whisper's `prompt`.
///
/// Whisper treats the prompt as the text that came *before* the audio, so it copies its script and
/// punctuation style. A prompt written in Traditional Chinese with full-width punctuation steers it
/// away from Simplified output, and listing the dictionary terms is the only vocabulary hint
/// Whisper has. Groq documents a 224-token limit for the prompt.
enum WhisperPrompt {
    /// Documented limit is 224 tokens; we budget below it because our count is an estimate.
    static let tokenBudget = 200

    static let chineseLead = "以下是台灣繁體中文的逐字稿，可能夾雜英文。"
    static let chineseTermsLabel = "專有名詞："
    static let englishTermsLabel = "Glossary: "

    static func build(keyterms: [String], languageCode: String?) -> String {
        let language = ProviderHTTP.isoLanguage(languageCode)
        let isChinese = language == nil || language == "zh"
        let lead = isChinese ? chineseLead : ""
        let label = isChinese ? chineseTermsLabel : englishTermsLabel
        let separator = isChinese ? "、" : ", "
        let terminator = isChinese ? "。" : "."

        var used = estimateTokens(lead) + estimateTokens(label) + estimateTokens(terminator)
        var chosen: [String] = []
        var seen = Set<String>()
        for raw in keyterms {
            let term = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let cost = estimateTokens(term) + (chosen.isEmpty ? 0 : estimateTokens(separator))
            // Skip terms that don't fit but keep trying shorter ones further down the list.
            guard used + cost <= tokenBudget else { continue }
            used += cost
            chosen.append(term)
        }
        guard !chosen.isEmpty else { return lead }
        return lead + label + chosen.joined(separator: separator) + terminator
    }

    /// Conservative token estimate for Whisper's multilingual byte-level BPE:
    /// CJK ideographs and full-width punctuation are 3 UTF-8 bytes and often 2–3 tokens each,
    /// Latin words are about one token per 3 letters, everything else one token.
    static func estimateTokens(_ text: String) -> Int {
        var tokens = 0
        var latinRun = 0
        func flushLatin() {
            if latinRun > 0 { tokens += (latinRun + 2) / 3 }
            latinRun = 0
        }
        for scalar in text.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                latinRun += 1
                continue
            }
            flushLatin()
            if scalar == " " {
                continue // a leading space merges into the next word's token
            } else if scalar.value >= 0x2E80 {
                tokens += 3
            } else {
                tokens += 1
            }
        }
        flushLatin()
        return tokens
    }

    /// Phrases Whisper is known to invent on silence or noise (subtitle credits, video outros).
    /// Only a transcript that consists *entirely* of one of these is discarded. Short phrases a user
    /// could really dictate ("謝謝", "Thank you") are deliberately not listed.
    static let knownHallucinations: [String] = [
        "字幕由amara.org社区提供", "字幕由amara.org社區提供",
        "請不吝點贊訂閱轉發打賞支持明鏡與點點欄目", "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "謝謝觀看", "谢谢观看", "感謝觀看", "感谢观看", "謝謝收看", "谢谢收看",
        "訂閱我的頻道", "订阅我的频道", "請訂閱我的頻道", "请订阅我的频道",
        "本字幕由志願者提供", "字幕志願者", "字幕志愿者",
        "thankyouforwatching", "thanksforwatching",
    ]

    /// Returns "" when the transcript is a known silence hallucination or just echoes our prompt.
    static func discardHallucination(_ text: String, prompt: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = comparisonKey(trimmed)
        guard !key.isEmpty else { return "" }
        if knownHallucinations.contains(key) { return "" }
        let promptKey = comparisonKey(prompt)
        if !promptKey.isEmpty, key == promptKey || key == comparisonKey(chineseLead) {
            return ""
        }
        return trimmed
    }

    /// Lowercased letters and digits only, so punctuation and spacing differences don't matter.
    private static func comparisonKey(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "."
        }))
    }
}
