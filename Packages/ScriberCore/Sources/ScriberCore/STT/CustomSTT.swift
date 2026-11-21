import Foundation
import ScriberShared

/// The user's own OpenAI-compatible speech-to-text service (`STTProviderKind.custom`):
/// `POST {customSTTBaseURL}/audio/transcriptions` with `model = customSTTModel` and
/// `Authorization: Bearer <APIKeyKind.custom key>`. Same request as Groq Whisper.
public struct CustomSTT: STTProvider {
    public let endpoint: CustomSTTEndpoint
    public let model: String
    let apiKey: String
    let timeout: TimeInterval
    let session: URLSession

    public init(endpoint: CustomSTTEndpoint, model: String, apiKey: String, timeout: TimeInterval = 240) {
        self.init(endpoint: endpoint, model: model, apiKey: apiKey, timeout: timeout, session: ProviderHTTP.defaultSession)
    }

    init(endpoint: CustomSTTEndpoint, model: String, apiKey: String, timeout: TimeInterval = 240, session: URLSession) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    public func transcribe(audioFile: URL, options: STTOptions) async throws -> String {
        do {
            return try await client.transcribe(audioFile: audioFile, options: options)
        } catch ProviderError.http(let status, _) where status == 404 || status == 405 {
            // For a built-in provider a 404 means the app is outdated; here it means the user's
            // URL or model name is wrong, so say that instead.
            throw CustomSTTError.endpointNotFound(status: status)
        }
    }

    var client: OpenAITranscription {
        OpenAITranscription(endpoint: endpoint.transcriptionsURL, model: model, apiKey: apiKey,
                            timeout: timeout, session: session, vendor: "custom")
    }
}

/// The custom engine's base URL, normalized: https only, no trailing slash, and a pasted full
/// `…/audio/transcriptions` URL reduced to its base. Query items (some gateways need one, e.g.
/// `?api-version=`) are kept and carried over to every endpoint.
public struct CustomSTTEndpoint: Equatable, Sendable {
    /// e.g. https://api.openai.com/v1
    public let baseURL: URL

    public var transcriptionsURL: URL { appending("audio/transcriptions") }
    public var modelsURL: URL { appending("models") }

    private static let transcriptionsSuffix = "/audio/transcriptions"

    /// Throws `CustomSTTError` (zh-Hant `errorDescription`) when the URL is missing or unusable.
    public static func parse(_ raw: String) throws -> CustomSTTEndpoint {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CustomSTTError.missingURL }
        // Newer Foundation percent-encodes invalid characters instead of failing; a space inside
        // a URL is a typo, not something to encode.
        guard !text.contains(where: \.isWhitespace) else { throw CustomSTTError.invalidURL }
        // "api.example.com/v1" → assume https rather than reject it.
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased() else {
            throw CustomSTTError.invalidURL
        }
        if scheme == "http" { throw CustomSTTError.insecureURL }
        guard scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw CustomSTTError.invalidURL
        }
        components.scheme = "https"
        components.fragment = nil
        if components.percentEncodedQuery?.isEmpty == true { components.percentEncodedQuery = nil }

        var path = trimmingTrailingSlashes(components.percentEncodedPath)
        if path.lowercased().hasSuffix(transcriptionsSuffix) {
            path = trimmingTrailingSlashes(String(path.dropLast(transcriptionsSuffix.count)))
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw CustomSTTError.invalidURL }
        return CustomSTTEndpoint(baseURL: url)
    }

    private func appending(_ suffix: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent(suffix)
        }
        components.percentEncodedPath += "/" + suffix
        return components.url ?? baseURL.appendingPathComponent(suffix)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Configuration problems of the custom engine. Separate from `ProviderError` on purpose:
/// nothing here is fixed by retrying, and every message points to Settings. Never contains the
/// URL or the key.
public enum CustomSTTError: Error, LocalizedError, Equatable, Sendable {
    case missingURL
    case invalidURL
    case insecureURL
    case missingModel
    /// 404 / 405 from the transcription endpoint: wrong URL or model name.
    case endpointNotFound(status: Int)

    public var errorDescription: String? {
        switch self {
        case .missingURL: return "還沒設定自訂語音辨識的網址，請到設定填寫"
        case .invalidURL: return "自訂語音辨識的網址格式不正確，請到設定檢查"
        case .insecureURL: return "自訂語音辨識的網址必須是 https:// 開頭"
        case .missingModel: return "還沒設定自訂語音辨識的模型名稱，請到設定填寫"
        case .endpointNotFound(let status): return "自訂語音辨識找不到這個網址或模型（\(status)），請到設定檢查"
        }
    }
}

/// What the custom engine reads from settings, as one snapshot (injectable for tests).
struct CustomSTTConfig: Sendable, Equatable {
    var baseURL: String
    var model: String

    static var current: CustomSTTConfig {
        let settings = AppSettings.shared
        return CustomSTTConfig(baseURL: settings.customSTTBaseURL, model: settings.customSTTModel)
    }

    func requireModel() throws -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomSTTError.missingModel }
        return trimmed
    }
}
