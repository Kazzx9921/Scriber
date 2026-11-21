import Foundation
import ScriberShared

// MARK: - Groq (OpenAI-compatible chat completions)

/// Docs: https://console.groq.com/docs/api-reference (chat completions)
///       https://console.groq.com/docs/models (model ids, speed)
///       https://console.groq.com/docs/reasoning (`reasoning_effort`, `include_reasoning` for gpt-oss)
public struct GroqPolish: PolishProvider {
    /// Production model on Groq (~500 tok/s). Strong multilingual instruction following;
    /// swap for "openai/gpt-oss-20b" (~1000 tok/s) if latency matters more than zh quality.
    public static let model = "openai/gpt-oss-120b"
    /// gpt-oss is a reasoning model and its reasoning counts toward the completion budget.
    static let reasoningHeadroom = 512

    let apiKey: String
    let session: URLSession
    let timeout: TimeInterval

    public init(apiKey: String, timeout: TimeInterval = 150) {
        self.init(apiKey: apiKey, timeout: timeout, session: ProviderHTTP.defaultSession)
    }

    init(apiKey: String, timeout: TimeInterval = 150, session: URLSession) {
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    public func polish(_ transcript: String, context: PolishContext) async throws -> String {
        let request = try makeRequest(transcript: transcript, context: context)
        let data = try await ProviderHTTP.withDeadline(seconds: timeout) { [session, apiKey] in
            try await ProviderHTTP.send(request, session: session, secret: apiKey)
        }
        let json = try ProviderHTTP.decodeJSONObject(data)
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw PolishError.invalidOutput
        }
        let content = message["content"] as? String ?? ""
        if (choice["finish_reason"] as? String) == "length" { throw PolishError.truncated }
        if message["refusal"] is String { throw PolishError.refused }
        return try PolishPrompt.finalize(content, transcript: transcript, context: context)
    }

    func makeRequest(transcript: String, context: PolishContext) throws -> URLRequest {
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [
                ["role": "system", "content": PolishPrompt.system(for: context)],
                ["role": "user", "content": PolishPrompt.userMessage(transcript: transcript, context: context)],
            ],
            "temperature": 0,
            "max_completion_tokens": PolishPrompt.maxOutputTokens(transcript: transcript, context: context)
                + Self.reasoningHeadroom,
            "reasoning_effort": "low",
            "include_reasoning": false,
            "stream": false,
        ]
        var request = URLRequest(url: GroqAPI.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

// MARK: - Anthropic Messages API

enum AnthropicAPI {
    static let baseURL = URL(string: "https://api.anthropic.com")!
    static let version = "2026-10-21"
}

/// Raw HTTP against the Messages API (Swift has no official Anthropic SDK).
///
/// Claude Haiku 5.5 notes that shape this request:
/// - sampling parameters (`temperature`, `top_p`, `top_k`) return a 400 on API version 2026-10-21,
///   so determinism comes from the prompt instead of `temperature: 0`;
/// - thinking is on by default; `thinking: {type: "disabled"}` is accepted at effort `low`,
///   which is the fastest configuration for a short rewrite;
/// - responses can contain non-text blocks, so text is read by block type, not position.
public struct AnthropicPolish: PolishProvider {
    public static let model = "claude-haiku-5-5"

    let apiKey: String
    let session: URLSession
    let timeout: TimeInterval

    public init(apiKey: String, timeout: TimeInterval = 150) {
        self.init(apiKey: apiKey, timeout: timeout, session: ProviderHTTP.defaultSession)
    }

    init(apiKey: String, timeout: TimeInterval = 150, session: URLSession) {
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    public func polish(_ transcript: String, context: PolishContext) async throws -> String {
        let request = try makeRequest(transcript: transcript, context: context)
        let data = try await ProviderHTTP.withDeadline(seconds: timeout) { [session, apiKey] in
            try await ProviderHTTP.send(request, session: session, secret: apiKey)
        }
        let json = try ProviderHTTP.decodeJSONObject(data)
        switch json["stop_reason"] as? String {
        case "refusal": throw PolishError.refused
        case "max_tokens": throw PolishError.truncated
        default: break
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return try PolishPrompt.finalize(text, transcript: transcript, context: context)
    }

    func makeRequest(transcript: String, context: PolishContext) throws -> URLRequest {
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": PolishPrompt.maxOutputTokens(transcript: transcript, context: context),
            "system": PolishPrompt.system(for: context),
            "messages": [
                ["role": "user", "content": PolishPrompt.userMessage(transcript: transcript, context: context)],
            ],
            "thinking": ["type": "disabled"],
            "output_config": ["effort": "low"],
        ]
        var request = URLRequest(url: AnthropicAPI.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicAPI.version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
