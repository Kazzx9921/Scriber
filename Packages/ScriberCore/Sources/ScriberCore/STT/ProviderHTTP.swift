import Foundation
import ScriberShared

// Shared networking helpers for every STT / polish provider.
// URLSession only; the session is injected so tests can install a URLProtocol stub.

enum ProviderHTTP {
    /// Ephemeral session: no disk cache (audio and transcripts never touch the URL cache), no cookies.
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 420
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Sends `request` and returns the body of a 2xx response.
    /// Every failure is mapped to `ProviderError`; `secret` is scrubbed from any server message we keep.
    static func send(_ request: URLRequest, session: URLSession, secret: String?) async throws -> Data {
        if Task.isCancelled { throw ProviderError.cancelled }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapTransportError(error)
        }
        if Task.isCancelled { throw ProviderError.cancelled }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("invalid-response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode,
                                     message: serverMessage(from: data, secret: secret))
        }
        return data
    }

    static func mapTransportError(_ error: Error) -> ProviderError {
        if let providerError = error as? ProviderError { return providerError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .network(ProviderError.timeoutCode)
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .network(ProviderError.offlineCode)
            default:
                return .network("url-error-\(urlError.code.rawValue)")
            }
        }
        return .network("transport")
    }

    /// Short diagnostic text from an error body. Never shown to the user verbatim; scrubbed anyway.
    static func serverMessage(from data: Data, secret: String?) -> String {
        var message = ""
        if let object = try? JSONSerialization.jsonObject(with: data) {
            message = extractMessage(object) ?? ""
        }
        if message.isEmpty {
            message = String(decoding: data.prefix(300), as: UTF8.self)
        }
        return redact(String(message.prefix(300)), secret: secret)
    }

    private static func extractMessage(_ object: Any) -> String? {
        if let dict = object as? [String: Any] {
            // OpenAI / Groq / Anthropic: {"error": {"message": ...}}
            if let error = dict["error"] {
                if let text = error as? String { return text }
                if let nested = extractMessage(error) { return nested }
            }
            // ElevenLabs: {"detail": {"status": ..., "message": ...}} or {"detail": [{"msg": ...}]}
            if let detail = dict["detail"] {
                if let text = detail as? String { return text }
                if let nested = detail as? [String: Any] {
                    let status = nested["status"] as? String
                    let msg = nested["message"] as? String
                    return [status, msg].compactMap { $0 }.joined(separator: ": ")
                }
                if let list = detail as? [[String: Any]] {
                    return list.compactMap { $0["msg"] as? String }.joined(separator: "; ")
                }
            }
            if let msg = dict["message"] as? String { return msg }
        }
        return nil
    }

    /// Removes the key itself and anything shaped like a credential.
    static func redact(_ text: String, secret: String?) -> String {
        var out = text
        if let secret, secret.count >= 4 {
            out = out.replacingOccurrences(of: secret, with: "[redacted]")
        }
        // Long opaque tokens (API keys, bearer tokens) → [redacted].
        if let regex = try? NSRegularExpression(pattern: "(?:sk|gsk|xi|key)?[-_]?[A-Za-z0-9_\\-]{24,}") {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "[redacted]")
        }
        return out
    }

    /// Runs `operation` but gives up after `seconds`, throwing a timeout `ProviderError`.
    /// Cancelling the caller cancels the operation.
    static func withDeadline<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    throw ProviderError.network(ProviderError.timeoutCode)
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw ProviderError.cancelled }
                return value
            }
        } catch {
            if Task.isCancelled { throw ProviderError.cancelled }
            // Transport-level errors become ProviderError; domain errors (e.g. PolishError) pass through.
            if error is CancellationError || error is URLError { throw mapTransportError(error) }
            throw error
        }
    }

    static func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.network("invalid-json")
        }
        return object
    }

    /// "zh-TW" / "zh_Hant" / "ZH" → "zh". nil or empty stays nil.
    static func isoLanguage(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { return nil }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return base.lowercased()
    }
}

// MARK: - Multipart

struct MultipartForm {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "Scriber-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.escape(name))\"; filename=\"\(Self.escape(filename))\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    func finalized() -> Data {
        var out = body
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    /// MIME type for the audio formats the recorder can produce.
    static func audioMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "mp3", "mpga", "mpeg": return "audio/mpeg"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "webm": return "audio/webm"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Audio file loading

enum AudioFile {
    static func load(_ url: URL) throws -> Data {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else { throw ProviderError.emptyResult }
            return data
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.network(ProviderError.audioUnreadableCode)
        }
    }
}
