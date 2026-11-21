import Foundation
import ScriberShared

/// ElevenLabs Scribe v3, batch speech-to-text (multipart upload, synchronous JSON result).
///
/// Docs: https://elevenlabs.io/docs/api-reference/speech-to-text/convert
///       https://elevenlabs.io/docs/overview/models (model id `scribe_v3`)
///       https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting
public struct ElevenLabsScribeSTT: STTProvider {
    static let baseURL = URL(string: "https://api.elevenlabs.io")!
    public static let modelID = "scribe_v3"

    /// Documented batch limits: ≤ 1000 keyterms, each ≤ 50 characters and ≤ 5 words,
    /// none of `< > { } [ ] \`. We cap the count at 100 because requests with more than 100
    /// keyterms are billed for at least 20 seconds, which would multiply the cost of short dictations.
    static let maxKeyterms = 100
    static let maxKeytermCharacters = 50
    static let maxKeytermWords = 5
    private static let forbiddenKeytermCharacters = CharacterSet(charactersIn: "<>{}[]\\")

    let apiKey: String
    let session: URLSession
    /// Scribe's `no_verbatim`: drop filler words, false starts and non-speech sounds at the STT level.
    let noVerbatim: Bool
    let timeout: TimeInterval

    public init(apiKey: String, noVerbatim: Bool = true, timeout: TimeInterval = 240) {
        self.init(apiKey: apiKey, noVerbatim: noVerbatim, timeout: timeout, session: ProviderHTTP.defaultSession)
    }

    init(apiKey: String, noVerbatim: Bool = true, timeout: TimeInterval = 240, session: URLSession) {
        self.apiKey = apiKey
        self.noVerbatim = noVerbatim
        self.timeout = timeout
        self.session = session
    }

    public func transcribe(audioFile: URL, options: STTOptions) async throws -> String {
        let audio = try AudioFile.load(audioFile)
        let request = makeRequest(audio: audio, filename: audioFile.lastPathComponent,
                                  mimeType: MultipartForm.audioMimeType(for: audioFile), options: options)
        let data = try await ProviderHTTP.withDeadline(seconds: timeout) { [session, apiKey] in
            try await ProviderHTTP.send(request, session: session, secret: apiKey)
        }
        let json = try ProviderHTTP.decodeJSONObject(data)
        if let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Multichannel shape: {"transcripts": [{"text": ...}]}. We never request it, but be lenient.
        if let transcripts = json["transcripts"] as? [[String: Any]] {
            return transcripts.compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw ProviderError.network("elevenlabs-unexpected-response")
    }

    func makeRequest(audio: Data, filename: String, mimeType: String, options: STTOptions) -> URLRequest {
        var form = MultipartForm()
        form.addField("model_id", Self.modelID)
        if let language = ProviderHTTP.isoLanguage(options.languageCode) {
            form.addField("language_code", language)
            // Mixed zh/en speech is the main use case: tell Scribe v3 English may appear too.
            if language != "en" {
                form.addField("secondary_language_codes", "en")
            }
        }
        // Plain text only: no "(laughter)" tags, no speaker labels, no timestamps payload.
        form.addField("tag_audio_events", "false")
        form.addField("diarize", "false")
        form.addField("timestamps_granularity", "none")
        if noVerbatim {
            form.addField("no_verbatim", "true")
        }
        // List-valued form fields are sent as repeated parts with the same name.
        for term in Self.sanitizedKeyterms(options.keyterms) {
            form.addField("keyterms", term)
        }
        form.addFile("file", filename: filename.isEmpty ? "audio.m4a" : filename, mimeType: mimeType, data: audio)

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/speech-to-text"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.finalized()
        return request
    }

    /// Applies the documented keyterm limits. Terms that break a limit are dropped, not truncated,
    /// because a truncated term would bias recognition toward a wrong spelling.
    static func sanitizedKeyterms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
                !forbiddenKeytermCharacters.contains($0)
            }))
            let term = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty,
                  term.count <= maxKeytermCharacters,
                  term.split(separator: " ").count <= maxKeytermWords else { continue }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(term)
            if out.count == maxKeyterms { break }
        }
        return out
    }
}
