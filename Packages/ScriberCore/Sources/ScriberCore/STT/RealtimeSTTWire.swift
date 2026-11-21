import Foundation
import ScriberShared

// Wire format of ElevenLabs real-time speech-to-text (Scribe v3 Live), kept pure (no sockets) so it
// is unit-tested against the documented and live-captured message shapes.
//
// Sources (fetched 2026-11-22):
//   API reference   https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
//   Commit guide    https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies
//   Event reference https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/event-reference
//   Server guide    https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/server-side-streaming
//   Keyterms        https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting
//   SDK ground truth elevenlabs-python src/elevenlabs/realtime/{scribe,connection}.py,
//                    elevenlabs-js src/wrapper/realtime/{scribe,connection}.ts
// Live-verified against wss://api.elevenlabs.io on 2026-11-22 (see docs/PRD-macOS版.md, 即時辨識).
//
// Protocol summary:
// - One WebSocket per dictation: GET wss://api.elevenlabs.io/v1/speech-to-text/realtime?<query>,
//   `xi-api-key` header. All options are query parameters; list options repeat the name
//   (`keyterms=a&keyterms=b`), exactly like the SDKs build them.
// - The server answers the upgrade with 101 even for a bad key or bad parameters, then sends one
//   JSON error event (`auth_error`, `invalid_request`, ...) and closes (1000 / 1008).
// - Otherwise it sends `session_started` right away; audio is sent after it.
// - Client → server: text frames `{"message_type":"input_audio_chunk","audio_base_64":…,
//   "commit":false,"sample_rate":16000}`; base64 of 16-bit little-endian mono PCM at 16 kHz.
//   0.1–1 s per chunk is the documented range.
// - A commit is the same message with empty audio and `"commit":true` (what the SDKs' `commit()`
//   sends). It needs ≥ 0.3 s of uncommitted audio: otherwise the server answers
//   `commit_throttled` and CLOSES the session (live-verified).
// - Server → client: `partial_transcript` {text, turn_probability} replaces the in-progress
//   segment; `committed_transcript` {text} is the final text of one segment (possibly ""), one per
//   commit. The server also commits by itself after ~36 s of uncommitted audio.

public enum RealtimeSTTWire {
    public static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    public static let modelID = "scribe_v3_live"
    public static let sampleRate = 16_000
    /// 16-bit mono PCM at `sampleRate`.
    public static let audioFormat = "pcm_16000"
    public static let bytesPerSecond = sampleRate * 2

    // Keyterms (keyterm-prompting page, realtime column): at most 50 terms and 1000 characters in
    // total; "no separate limit" per term. Live check: 51+ terms → `invalid_request`, close 1008;
    // a 32-character term was accepted. We still cap a term at 50 characters, the batch and
    // keyterm-library per-term limit, so the same dictionary entries are used everywhere.
    static let maxKeyterms = 50
    static let maxKeytermTotalCharacters = 1000
    static let maxKeytermCharacters = 50
    // Keyterm library (Scribe v3 Live only): ≤ 10,000 terms, ≤ 50 characters each, ≤ 2 MB, sent as
    // `keyterm_library` in the FIRST input_audio_chunk only (a later one → input_error + close).
    static let maxLibraryTerms = 10_000
    private static let forbiddenKeytermCharacters = CharacterSet(charactersIn: "<>{}[]\\")

    /// Minimum uncommitted audio before a commit (server: "You need at least 0.3s of uncommitted
    /// audio before committing", then it closes the session). We keep a small margin.
    static let minimumCommitBytes = Int(0.35 * Double(bytesPerSecond))

    /// What the session asks for. Everything here becomes a query parameter.
    public struct Parameters: Equatable, Sendable {
        /// ISO-639-1 hint, nil = auto detect.
        public var languageCode: String?
        /// Other languages that may appear (`secondary_languages`, repeated).
        public var secondaryLanguages: [String]
        /// Personal-dictionary terms (sanitized to the realtime limits when the URL is built).
        public var keyterms: [String]
        /// Scribe's `no_verbatim`: drop fillers and false starts, like the batch request.
        public var noVerbatim: Bool

        public init(languageCode: String? = "zh", secondaryLanguages: [String]? = nil,
                    keyterms: [String] = [], noVerbatim: Bool = true) {
            let language = ProviderHTTP.isoLanguage(languageCode)
            self.languageCode = language
            // Mixed zh/en speech is the main use case (same choice as the batch request).
            self.secondaryLanguages = secondaryLanguages ?? (language == nil || language == "en" ? [] : ["en"])
            self.keyterms = keyterms
            self.noVerbatim = noVerbatim
        }
    }

    // MARK: Handshake

    /// The terms that go into the `keyterms` query parameter and those left for the keyterm library.
    static func splitKeyterms(_ terms: [String]) -> (query: [String], library: [String]) {
        var query: [String] = []
        var library: [String] = []
        var total = 0
        var seen = Set<String>()
        for raw in terms {
            let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
                !forbiddenKeytermCharacters.contains($0)
            }))
            let term = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // Dropped, not truncated: a truncated term would bias recognition toward a wrong spelling.
            guard !term.isEmpty, term.count <= maxKeytermCharacters,
                  seen.insert(term.lowercased()).inserted else { continue }
            if query.count < maxKeyterms, total + term.count <= maxKeytermTotalCharacters {
                query.append(term)
                total += term.count
            } else if library.count < maxLibraryTerms {
                library.append(term)
            }
        }
        return (query, library)
    }

    static func url(for parameters: Parameters, endpoint: URL = endpoint) -> URL {
        var items = [URLQueryItem(name: "model_id", value: modelID),
                     URLQueryItem(name: "audio_format", value: audioFormat),
                     // Manual: we decide when a segment ends (and send the final commit at stop).
                     URLQueryItem(name: "commit_strategy", value: "manual")]
        if let language = parameters.languageCode {
            items.append(URLQueryItem(name: "language_code", value: language))
        }
        for language in parameters.secondaryLanguages {
            items.append(URLQueryItem(name: "secondary_languages", value: language))
        }
        if parameters.noVerbatim {
            items.append(URLQueryItem(name: "no_verbatim", value: "true"))
        }
        for term in splitKeyterms(parameters.keyterms).query {
            items.append(URLQueryItem(name: "keyterms", value: term))
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        // URLComponents leaves "+" unescaped, which servers may read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func request(for parameters: Parameters, apiKey: String, endpoint: URL = endpoint) -> URLRequest {
        var request = URLRequest(url: url(for: parameters, endpoint: endpoint))
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        // Generous: for a WebSocket this also bounds how long a receive may wait, and the server
        // can stay quiet through long pauses. Our own timers handle connect and commit timeouts.
        request.timeoutInterval = 300
        return request
    }

    // MARK: Client → server

    /// One `input_audio_chunk` text frame. `pcm` is 16-bit LE mono at 16 kHz. Built by hand so the
    /// bytes are deterministic (base64 never needs JSON escaping); `library` only on the first chunk.
    static func audioChunk(_ pcm: Data, commit: Bool = false, library: [String] = []) -> String {
        var json = "{\"message_type\":\"input_audio_chunk\",\"audio_base_64\":\""
        json += pcm.base64EncodedString()
        json += "\",\"commit\":\(commit ? "true" : "false"),\"sample_rate\":\(sampleRate)"
        if !library.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: library),
           let array = String(data: data, encoding: .utf8) {
            json += ",\"keyterm_library\":" + array
        }
        json += "}"
        return json
    }

    /// The commit message, identical to the SDKs' `commit()`: empty audio, `commit: true`.
    static var commitMessage: String { audioChunk(Data(), commit: true) }

    // MARK: Server → client

    /// Error `message_type`s from the API reference (each carries an `error` string).
    static let errorTypes: Set<String> = [
        "error", "auth_error", "quota_exceeded", "commit_throttled", "unaccepted_terms",
        "unaccepted_terms_error", "rate_limited", "queue_overflow", "resource_exhausted",
        "session_time_limit_exceeded", "input_error", "invalid_request", "chunk_size_exceeded",
        "insufficient_audio_activity", "transcriber_error",
    ]

    /// Known events we never ask for. Ignored on purpose: `committed_transcript_with_timestamps`
    /// repeats the committed text, so counting it would duplicate the transcript.
    static let ignoredTypes: Set<String> = [
        "committed_transcript_with_timestamps", "final_transcript_with_timestamps",
        "committed_transcript_entities", "redacted_transcript", "edited_transcript",
        "diarized_transcript", "speakers_merged",
    ]

    static func decode(_ text: String) -> RealtimeServerEvent {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown("malformed")
        }
        guard let type = object["message_type"] as? String else { return .unknown("no-type") }
        switch type {
        case "session_started":
            return .sessionStarted(sessionID: object["session_id"] as? String)
        case "partial_transcript":
            return .partial(object["text"] as? String ?? "")
        case "final_transcript":
            // Only in the JS SDK's types ("will not change, but the segment is not yet committed");
            // the event reference says the public API does not send it. If it ever arrives it is
            // display text only: the committed_transcript that follows is the one we keep.
            return .partial(object["text"] as? String ?? "")
        case "committed_transcript":
            return .committed(object["text"] as? String ?? "")
        case "warning":
            return .warning
        default:
            if errorTypes.contains(type) {
                return .serverError(type: type, message: object["error"] as? String ?? "")
            }
            if ignoredTypes.contains(type) { return .ignored(type) }
            return .unknown(type)
        }
    }

    /// Server error → user-facing error (zh-Hant through `ProviderError`). The server text is kept
    /// only as a classifier, never shown.
    static func providerError(forServerError type: String, message: String) -> ProviderError {
        switch type {
        case "auth_error":
            return .http(status: 401, message: type)
        case "quota_exceeded":
            return .http(status: 402, message: "quota_exceeded")
        case "rate_limited", "commit_throttled":
            return .http(status: 429, message: type)
        case "queue_overflow", "resource_exhausted", "transcriber_error", "error":
            return .http(status: 503, message: type)
        case "session_time_limit_exceeded":
            return .network(ProviderError.realtimeSessionLimitCode)
        case "unaccepted_terms", "unaccepted_terms_error":
            return .http(status: 403, message: type)
        default: // invalid_request, input_error, chunk_size_exceeded, insufficient_audio_activity
            return .http(status: 400, message: type)
        }
    }

    /// Short, content-free form of a server error string for the diagnostic log: key-like tokens
    /// redacted and quoted values (which could echo a dictionary term) masked.
    static func logSafe(_ message: String, secret: String?) -> String {
        var out = ProviderHTTP.redact(String(message.prefix(300)), secret: secret)
        if let regex = try? NSRegularExpression(pattern: "'[^']*'|\"[^\"]*\"") {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: "'…'")
        }
        out = out.replacingOccurrences(of: "\n", with: " ")
        return String(out.prefix(140))
    }
}

/// One decoded server message.
public enum RealtimeServerEvent: Equatable, Sendable {
    case sessionStarted(sessionID: String?)
    /// Interim text of the in-progress segment; each one replaces the previous.
    case partial(String)
    /// Final text of one segment (may be empty).
    case committed(String)
    case serverError(type: String, message: String)
    case warning
    /// A known event we did not ask for.
    case ignored(String)
    /// Unknown `message_type`, or not a JSON object ("malformed" / "no-type").
    case unknown(String)
}
