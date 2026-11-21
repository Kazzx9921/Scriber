import Foundation
import ScriberShared

// CONTRACT FILE — implementations owned by the "providers + pipeline" agent.

public struct PolishContext: Sendable {
    public var mode: DictationMode
    public var dictionary: [DictionaryEntry]
    /// Text to rewrite when mode == .edit.
    public var selectedText: String?
    public var translateTarget: String
    public var fieldHint: FieldHint
    public var spaceBetweenCJKAndLatin: Bool
    public init(mode: DictationMode = .dictate, dictionary: [DictionaryEntry] = [], selectedText: String? = nil,
                translateTarget: String = "English", fieldHint: FieldHint = .general,
                spaceBetweenCJKAndLatin: Bool = true) {
        self.mode = mode; self.dictionary = dictionary; self.selectedText = selectedText
        self.translateTarget = translateTarget; self.fieldHint = fieldHint
        self.spaceBetweenCJKAndLatin = spaceBetweenCJKAndLatin
    }
}

public protocol PolishProvider: Sendable {
    /// Turns a raw transcript into final text. Must not answer questions or add content.
    func polish(_ transcript: String, context: PolishContext) async throws -> String
}

public enum PolishFactory {
    /// Returns nil for `.off`. Throws `.missingAPIKey` if the provider's key is absent.
    public static func make(_ kind: PolishProviderKind, keys: KeychainStore) throws -> (any PolishProvider)? {
        try make(kind, keys: keys, session: ProviderHTTP.defaultSession)
    }

    static func make(_ kind: PolishProviderKind, keys: KeychainStore, session: URLSession) throws -> (any PolishProvider)? {
        switch kind {
        case .off:
            return nil
        case .groq:
            return GroqPolish(apiKey: try STTFactory.requireKey(.groq, keys: keys), session: session)
        case .anthropic:
            return AnthropicPolish(apiKey: try STTFactory.requireKey(.anthropic, keys: keys), session: session)
        }
    }
}

/// No-LLM cleanup used when polish is off, and as the fallback when the LLM call fails or is too slow.
public enum RuleBasedCleanup {
    /// Removes obvious fillers (嗯、呃、那個那個…), collapses stutters/repeats, trims, fixes spacing.
    /// Conservative: legitimate reduplication (謝謝、看看、慢慢…) is kept, and input that is nothing
    /// but fillers (e.g. a chat reply of "嗯嗯") is returned unchanged rather than emptied.
    public static func clean(_ text: String) -> String {
        CleanupRules.clean(text)
    }
}
