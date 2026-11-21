import Foundation
import ScriberShared

// CONTRACT FILE — implementations owned by the "providers + pipeline" agent.

public struct STTOptions: Sendable {
    /// ISO-639-1 hint, nil = auto detect. Mixed zh/en speech is the main use case.
    public var languageCode: String?
    /// Personal-dictionary terms that must be spelled exactly like this.
    public var keyterms: [String]
    public init(languageCode: String? = nil, keyterms: [String] = []) {
        self.languageCode = languageCode; self.keyterms = keyterms
    }
}

public protocol STTProvider: Sendable {
    /// `audioFile` is a local m4a/AAC (16 kHz mono) or wav file. Returns the raw transcript.
    func transcribe(audioFile: URL, options: STTOptions) async throws -> String
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case missingAPIKey(APIKeyKind)
    case http(status: Int, message: String)
    case network(String)
    case emptyResult
    case cancelled

    /// User-facing zh-Hant text. Must never contain the API key.
    /// Server-provided messages (`http.message`, `network` detail) are diagnostics only and never shown.
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(.custom):
            return "還沒設定自訂語音辨識的 API key，請到設定填寫"
        case .missingAPIKey(let kind):
            return "還沒設定 \(kind.serviceName) 的 API key，請到設定填寫"
        case .http(let status, let message):
            // The server message is only used to classify, never displayed.
            let lowered = message.lowercased()
            if status == 402 || lowered.contains("quota_exceeded") || lowered.contains("insufficient_quota")
                || lowered.contains("credit balance") {
                return "帳戶額度不足，請到服務商後台確認"
            }
            switch status {
            case 401, 403: return "API key 無效或沒有權限，請到設定檢查"
            case 404: return "找不到指定的模型或服務（404），可能需要更新 App"
            case 408, 504: return "服務回應逾時，請再試一次"
            case 413: return "錄音檔太大，請說短一點再試"
            case 400, 415, 422: return "服務無法處理這次的請求（\(status)）"
            case 429: return "用量或頻率超過上限，請稍後再試"
            case 500...599: return "服務暫時無法使用（\(status)），請稍後再試"
            default: return "服務回應錯誤（\(status)）"
            }
        case .network(let code):
            switch code {
            case Self.timeoutCode: return "連線逾時，請再試一次"
            case Self.offlineCode: return "沒有網路連線，請檢查網路後再試"
            case Self.audioUnreadableCode: return "讀不到錄音檔，請再錄一次"
            case Self.realtimeConnectTimeoutCode, Self.realtimeCommitTimeoutCode:
                return "即時辨識連線逾時，請再試一次"
            case Self.realtimeSessionLimitCode: return "即時辨識已達單次時間上限，請再試一次"
            case Self.realtimeStalledCode, Self.realtimeClosedCode:
                return "網路連線失敗，即時辨識中斷了"
            default: return "網路連線失敗，請稍後再試"
            }
        case .emptyResult: return "沒有辨識到內容，請再說一次"
        case .cancelled: return "已取消"
        }
    }

    // Diagnostic codes carried by `.network(_:)`; `errorDescription` turns them into zh-Hant text.
    static let timeoutCode = "timeout"
    static let offlineCode = "offline"
    static let audioUnreadableCode = "audio-file-unreadable"
    // Real-time transcription (`RealtimeSTTSession`).
    static let realtimeConnectTimeoutCode = "realtime-connect-timeout"
    static let realtimeCommitTimeoutCode = "realtime-commit-timeout"
    static let realtimeSessionLimitCode = "realtime-session-limit"
    static let realtimeStalledCode = "realtime-stalled"
    static let realtimeClosedCode = "realtime-closed"

    /// True for timeouts, either ours (deadline) or URLSession's.
    public var isTimeout: Bool {
        switch self {
        case .network(let code):
            return code == Self.timeoutCode || code == Self.realtimeConnectTimeoutCode
                || code == Self.realtimeCommitTimeoutCode
        case .http(let status, _): return status == 408 || status == 504
        default: return false
        }
    }
}

extension APIKeyKind {
    /// Brand name used in user-facing messages. Internal on purpose so it can't clash with app-side extensions.
    var serviceName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .groq: return "Groq"
        case .anthropic: return "Anthropic"
        case .custom: return "自訂語音辨識"
        }
    }
}

public enum STTFactory {
    /// Builds the provider for `kind`. Throws `.missingAPIKey` if the key is absent; for `.custom`
    /// also `CustomSTTError` when the URL or model in settings is missing or unusable.
    public static func make(_ kind: STTProviderKind, keys: KeychainStore) throws -> any STTProvider {
        try make(kind, keys: keys, session: ProviderHTTP.defaultSession)
    }

    static func make(_ kind: STTProviderKind, keys: KeychainStore, session: URLSession,
                     custom: @autoclosure () -> CustomSTTConfig = CustomSTTConfig.current) throws -> any STTProvider {
        switch kind {
        case .elevenLabsScribe:
            let key = try requireKey(.elevenLabs, keys: keys)
            return ElevenLabsScribeSTT(apiKey: key, session: session)
        case .groqWhisperLarge:
            let key = try requireKey(.groq, keys: keys)
            return GroqWhisperSTT(apiKey: key, model: .largeV3, session: session)
        case .groqWhisperTurbo:
            let key = try requireKey(.groq, keys: keys)
            return GroqWhisperSTT(apiKey: key, model: .largeV3Turbo, session: session)
        case .custom:
            // Settings first (URL, then model), then the key: the first thing missing is reported.
            let config = custom()
            let endpoint = try CustomSTTEndpoint.parse(config.baseURL)
            let model = try config.requireModel()
            let key = try requireKey(.custom, keys: keys)
            return CustomSTT(endpoint: endpoint, model: model, apiKey: key, session: session)
        }
    }

    /// Cheap authenticated request to check a key. Returns nil on success, else a user-facing message.
    ///
    /// `.custom` checks the key against the base URL saved in settings (`customSTTBaseURL`) with
    /// `GET {base}/models`. Not every OpenAI-compatible server implements that endpoint, so a 404
    /// or 405 there means "cannot verify" and counts as success (logged as such); 401/403 and
    /// network failures are still reported.
    public static func validateKey(_ kind: APIKeyKind, key: String) async -> String? {
        await validateKey(kind, key: key, session: ProviderHTTP.defaultSession)
    }

    /// Same as `validateKey(.custom, key:)` but against a base URL that may not be saved yet
    /// (e.g. while the user is still editing the field).
    public static func validateCustomKey(_ key: String, baseURL: String) async -> String? {
        await validateKey(.custom, key: key, session: ProviderHTTP.defaultSession, customBaseURL: baseURL)
    }

    static func validateKey(_ kind: APIKeyKind, key rawKey: String, session: URLSession,
                            customBaseURL: String? = nil) async -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "請先輸入 API key" }
        var request: URLRequest
        switch kind {
        case .elevenLabs:
            // GET /v1/user — returns the account for the key, no usage cost.
            request = URLRequest(url: ElevenLabsScribeSTT.baseURL.appendingPathComponent("v1/user"))
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .groq:
            // GET /openai/v1/models — lists models, no usage cost.
            request = URLRequest(url: GroqAPI.baseURL.appendingPathComponent("models"))
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            // GET /v1/models — lists models, no usage cost.
            request = URLRequest(url: AnthropicAPI.baseURL.appendingPathComponent("v1/models"))
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicAPI.version, forHTTPHeaderField: "anthropic-version")
        case .custom:
            // GET {base}/models — the OpenAI-compatible model list, no usage cost.
            let endpoint: CustomSTTEndpoint
            do {
                endpoint = try CustomSTTEndpoint.parse(customBaseURL ?? CustomSTTConfig.current.baseURL)
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? CustomSTTError.invalidURL.errorDescription
            }
            request = URLRequest(url: endpoint.modelsURL)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let finalRequest = request
        do {
            _ = try await ProviderHTTP.withDeadline(seconds: 10) {
                try await ProviderHTTP.send(finalRequest, session: session, secret: key)
            }
            return nil
        } catch ProviderError.http(let status, let message)
            where kind == .elevenLabs && status == 401 && message.contains("missing_permissions") {
            // A restricted ElevenLabs key without `user_read` still authenticated fine;
            // speech-to-text only needs its own permission.
            return nil
        } catch ProviderError.http(let status, _) where kind == .custom && (status == 404 || status == 405) {
            // The server has no model list: the key cannot be verified this way. Assume it is fine;
            // a wrong key still surfaces as 401 on the first dictation.
            DiagLog.log("stt", "custom key check: GET models answered \(status), cannot verify, assumed OK")
            return nil
        } catch let error as ProviderError {
            return error.errorDescription
        } catch {
            return ProviderError.network("validate").errorDescription
        }
    }

    static func requireKey(_ kind: APIKeyKind, keys: KeychainStore) throws -> String {
        guard let key = keys.key(for: kind)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ProviderError.missingAPIKey(kind)
        }
        return key
    }
}
