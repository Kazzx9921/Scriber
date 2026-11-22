import Foundation
import ScriberShared

// File-transcription requests for each engine. Same endpoints, keys and keyterm rules as
// dictation; the differences are timing data (requested whenever the engine has it), speaker
// labels (Scribe only), a streamed request body (the audio is never held in memory) and longer
// timeouts on a separate session.

public enum FileTranscriberFactory {
    /// Builds the file transcriber for the engine selected in settings. Throws like `STTFactory.make`
    /// (`ProviderError.missingAPIKey`, `CustomSTTError`).
    public static func make(_ kind: STTProviderKind, keys: KeychainStore = .shared) throws -> any FileTranscriber {
        try make(kind, keys: keys, session: ProviderHTTP.fileSession)
    }

    static func make(_ kind: STTProviderKind, keys: KeychainStore, session: URLSession,
                     custom: @autoclosure () -> CustomSTTConfig = CustomSTTConfig.current) throws -> any FileTranscriber {
        switch kind {
        case .elevenLabsScribe:
            return ElevenLabsFileTranscriber(apiKey: try STTFactory.requireKey(.elevenLabs, keys: keys), session: session)
        case .groqWhisperLarge:
            return WhisperFileTranscriber(engine: kind, apiKey: try STTFactory.requireKey(.groq, keys: keys),
                                          model: GroqWhisperSTT.Model.largeV3.rawValue, session: session)
        case .groqWhisperTurbo:
            return WhisperFileTranscriber(engine: kind, apiKey: try STTFactory.requireKey(.groq, keys: keys),
                                          model: GroqWhisperSTT.Model.largeV3Turbo.rawValue, session: session)
        case .custom:
            let config = custom()
            let endpoint = try CustomSTTEndpoint.parse(config.baseURL)
            let model = try config.requireModel()
            let key = try STTFactory.requireKey(.custom, keys: keys)
            return PlainFileTranscriber(engine: .custom, capabilities: .custom,
                                        provider: CustomSTT(endpoint: endpoint, model: model, apiKey: key,
                                                            timeout: 600, session: session))
        }
    }

    /// What `kind` can do, without needing a key (for the options shown before starting).
    public static func capabilities(of kind: STTProviderKind) -> FileTranscriptionCapabilities {
        switch kind {
        case .elevenLabsScribe: .elevenLabs
        case .groqWhisperLarge, .groqWhisperTurbo: .groq
        case .custom: .custom
        }
    }
}

// MARK: - ElevenLabs Scribe v3

/// `POST /v1/speech-to-text` with `timestamps_granularity=word` and, on request, `diarize=true`.
/// Response: `{"text", "words": [{"text", "start", "end", "type": word|spacing|audio_event, "speaker_id"}]}`.
/// Docs: https://elevenlabs.io/docs/api-reference/speech-to-text/convert
struct ElevenLabsFileTranscriber: FileTranscriber {
    let apiKey: String
    let session: URLSession
    var engine: STTProviderKind { .elevenLabsScribe }
    var capabilities: FileTranscriptionCapabilities { .elevenLabs }

    func fields(_ request: FileSTTRequest) -> [(String, String)] {
        var fields: [(String, String)] = [("model_id", ElevenLabsScribeSTT.modelID)]
        if let language = ProviderHTTP.isoLanguage(request.languageCode) {
            fields.append(("language_code", language))
            if language != "en" { fields.append(("secondary_language_codes", "en")) }
        }
        fields.append(("tag_audio_events", "false"))
        fields.append(("diarize", request.diarize ? "true" : "false"))
        fields.append(("timestamps_granularity", "word"))
        fields.append(("no_verbatim", "true"))
        for term in ElevenLabsScribeSTT.sanitizedKeyterms(request.keyterms) {
            fields.append(("keyterms", term))
        }
        return fields
    }

    func transcribe(file: URL, request: FileSTTRequest) async throws -> TimedText {
        var http = URLRequest(url: ElevenLabsScribeSTT.baseURL.appendingPathComponent("v1/speech-to-text"))
        http.httpMethod = "POST"
        http.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await ProviderHTTP.uploadMultipart(http, fields: fields(request), file: file,
                                                          timeout: request.timeout, session: session, secret: apiKey)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> TimedText {
        let json = try ProviderHTTP.decodeJSONObject(data)
        guard let text = json["text"] as? String else {
            throw ProviderError.network("elevenlabs-unexpected-response")
        }
        let words = json["words"] as? [[String: Any]] ?? []
        var units: [TimedText.Unit] = []
        var spacing = ""
        var lastEnd: TimeInterval = 0
        for word in words {
            let type = word["type"] as? String ?? "word"
            let piece = word["text"] as? String ?? ""
            switch type {
            case "spacing":
                spacing += piece
            case "word":
                let start = (word["start"] as? Double) ?? lastEnd
                let end = max(start, (word["end"] as? Double) ?? start)
                units.append(TimedText.Unit(text: spacing + piece, start: start, end: end,
                                            speaker: word["speaker_id"] as? String))
                spacing = ""
                lastEnd = end
            default:
                continue // audio events: not requested; ignored if they come anyway
            }
        }
        return TimedText(text: text.trimmingCharacters(in: .whitespacesAndNewlines), granularity: .word, units: units)
    }
}

// MARK: - Groq Whisper

/// OpenAI-compatible `/audio/transcriptions` with `response_format=verbose_json` and
/// `timestamp_granularities[]=segment`. Segments Whisper is likely to have invented on silence
/// (`no_speech_prob > 0.6` with `avg_logprob < -1`, the reference implementation's rule, or a
/// known subtitle-credit phrase) are dropped.
/// Docs: https://console.groq.com/docs/speech-to-text
struct WhisperFileTranscriber: FileTranscriber {
    let engine: STTProviderKind
    let apiKey: String
    let model: String
    let session: URLSession
    var capabilities: FileTranscriptionCapabilities { .groq }

    static func prompt(_ request: FileSTTRequest) -> String {
        // Auto-detect must not be steered into Chinese by the zh-Hant lead sentence.
        WhisperPrompt.build(keyterms: request.keyterms, languageCode: request.languageCode ?? "en")
    }

    func fields(_ request: FileSTTRequest) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", "verbose_json"),
            ("timestamp_granularities[]", "segment"),
            ("temperature", "0"),
        ]
        if let language = ProviderHTTP.isoLanguage(request.languageCode) {
            fields.append(("language", language))
        }
        let prompt = Self.prompt(request)
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        return fields
    }

    func transcribe(file: URL, request: FileSTTRequest) async throws -> TimedText {
        var http = URLRequest(url: GroqAPI.baseURL.appendingPathComponent("audio/transcriptions"))
        http.httpMethod = "POST"
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await ProviderHTTP.uploadMultipart(http, fields: fields(request), file: file,
                                                          timeout: request.timeout, session: session, secret: apiKey)
        return try Self.parse(data, prompt: Self.prompt(request))
    }

    static func parse(_ data: Data, prompt: String) throws -> TimedText {
        let json = try ProviderHTTP.decodeJSONObject(data)
        guard let text = json["text"] as? String else {
            throw ProviderError.network("groq-unexpected-response")
        }
        guard let segments = json["segments"] as? [[String: Any]], !segments.isEmpty else {
            return TimedText(text: WhisperPrompt.discardHallucination(text, prompt: prompt))
        }
        var units: [TimedText.Unit] = []
        for segment in segments {
            let piece = segment["text"] as? String ?? ""
            let noSpeech = segment["no_speech_prob"] as? Double ?? 0
            let logprob = segment["avg_logprob"] as? Double ?? 0
            if noSpeech > 0.6 && logprob < -1 { continue }
            guard !WhisperPrompt.discardHallucination(piece, prompt: prompt).isEmpty else { continue }
            let start = segment["start"] as? Double ?? units.last?.end ?? 0
            let end = max(start, segment["end"] as? Double ?? start)
            units.append(TimedText.Unit(text: piece, start: start, end: end))
        }
        let joined = units.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return TimedText(text: joined, granularity: .segment, units: units)
    }
}

// MARK: - Text-only engines

/// Any `STTProvider` (the custom engine): text only, no timings, no speaker labels.
struct PlainFileTranscriber: FileTranscriber {
    let engine: STTProviderKind
    let capabilities: FileTranscriptionCapabilities
    let provider: any STTProvider

    func transcribe(file: URL, request: FileSTTRequest) async throws -> TimedText {
        let text = try await provider.transcribe(audioFile: file,
                                                 options: STTOptions(languageCode: request.languageCode,
                                                                     keyterms: request.keyterms))
        return TimedText(text: text)
    }
}

// MARK: - HTTP

extension ProviderHTTP {
    /// For file transcription: whole-file requests (speaker labels) can upload and process for a
    /// long time, so the resource limit is hours, not the dictation session's 7 minutes. Each
    /// request still carries its own deadline (`FileSTTRequest.timeout`).
    static let fileSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3 * 3600
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// Writes a multipart body (fields, then the audio file streamed from disk) to a temporary
    /// file next to the audio, uploads it, and deletes it. Memory use is independent of file size.
    static func uploadMultipart(_ request: URLRequest, fields: [(String, String)], file: URL,
                                timeout: TimeInterval, session: URLSession, secret: String?) async throws -> Data {
        let boundary = "Scriber-\(UUID().uuidString)"
        let body = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString.prefix(8)).body")
        defer { try? FileManager.default.removeItem(at: body) }
        do {
            try MultipartFileBody.write(fields: fields, file: file,
                                        mimeType: MultipartForm.audioMimeType(for: file),
                                        boundary: boundary, to: body)
        } catch {
            throw ProviderError.network(ProviderError.audioUnreadableCode)
        }
        var request = request
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let finalRequest = request
        return try await withDeadline(seconds: timeout) {
            try await upload(finalRequest, bodyFile: body, session: session, secret: secret)
        }
    }

    /// `send` for a body on disk; 429 becomes `RateLimitedError` with the `Retry-After` seconds.
    static func upload(_ request: URLRequest, bodyFile: URL, session: URLSession, secret: String?) async throws -> Data {
        if Task.isCancelled { throw ProviderError.cancelled }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: bodyFile)
        } catch {
            throw mapTransportError(error)
        }
        if Task.isCancelled { throw ProviderError.cancelled }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("invalid-response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = serverMessage(from: data, secret: secret)
            if http.statusCode == 429 {
                throw RateLimitedError(retryAfter: retryAfter(http.value(forHTTPHeaderField: "Retry-After")),
                                       message: message)
            }
            throw ProviderError.http(status: http.statusCode, message: message)
        }
        return data
    }

    /// `Retry-After` as seconds (the delta-seconds form; HTTP dates are rare for APIs and ignored).
    static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), let seconds = Double(value),
              seconds >= 0, seconds.isFinite else { return nil }
        return min(seconds, 300)
    }
}

/// multipart/form-data written to a file: text fields, then one `file` part streamed in 1 MB pieces.
enum MultipartFileBody {
    static func write(fields: [(String, String)], file: URL, mimeType: String, boundary: String, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        func put(_ string: String) throws { try out.write(contentsOf: Data(string.utf8)) }
        for (name, value) in fields {
            try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(name))\"\r\n\r\n")
            try put(value)
            try put("\r\n")
        }
        let filename = file.lastPathComponent.isEmpty ? "audio.m4a" : file.lastPathComponent
        try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(escape(filename))\"\r\n")
        try put("Content-Type: \(mimeType)\r\n\r\n")
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var copied = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
            copied += chunk.count
        }
        guard copied > 0 else { throw ProviderError.emptyResult }
        try put("\r\n--\(boundary)--\r\n")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
