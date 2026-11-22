import Foundation
import ScriberShared

// CONTRACT FILE — implementation owned by the "providers + pipeline" agent.

public struct PipelineResult: Sendable {
    public var rawTranscript: String
    public var finalText: String
    public var sttMillis: Int
    public var polishMillis: Int
    public var sttProvider: STTProviderKind
    /// The polish that actually produced `finalText`: `.off` when rule-based cleanup ran,
    /// including when the configured LLM failed or was skipped for a very short transcript.
    public var polishProvider: PolishProviderKind
    /// The transcript came from a real-time session (`run(transcript:…)`), not an upload.
    /// `sttMillis` is then the wait for the final commit after the user stopped.
    public var usedRealtime: Bool
    public init(rawTranscript: String, finalText: String, sttMillis: Int, polishMillis: Int,
                sttProvider: STTProviderKind, polishProvider: PolishProviderKind, usedRealtime: Bool = false) {
        self.rawTranscript = rawTranscript; self.finalText = finalText
        self.sttMillis = sttMillis; self.polishMillis = polishMillis
        self.sttProvider = sttProvider; self.polishProvider = polishProvider
        self.usedRealtime = usedRealtime
    }
}

/// Settings snapshot taken once per run, so a settings change mid-run can't mix configurations.
struct PipelineConfig: Sendable {
    var sttProvider: STTProviderKind
    var polishProvider: PolishProviderKind
    var forceTraditional: Bool
    var spaceBetweenCJKAndLatin: Bool
    /// Punctuation preference for finished text (see `PunctuationStyler`).
    var punctuationRule: PunctuationRule = .dropFinalPeriod
    var punctuationLimit: Int = 20
    var translateTarget: String
    /// STT language hint. Mixed zh/en speech is the main use case, and Whisper needs "zh" to stay in Chinese.
    var languageCode: String? = "zh"
    /// Transcripts with at most this many units (CJK characters or Latin words) skip the LLM.
    var shortTranscriptLimit: Int = 5
    /// Hard cap on the LLM call, on top of the provider's own timeout.
    var polishTimeout: TimeInterval = 4.5

    init(sttProvider: STTProviderKind, polishProvider: PolishProviderKind, forceTraditional: Bool,
         spaceBetweenCJKAndLatin: Bool, translateTarget: String) {
        self.sttProvider = sttProvider; self.polishProvider = polishProvider
        self.forceTraditional = forceTraditional; self.spaceBetweenCJKAndLatin = spaceBetweenCJKAndLatin
        self.translateTarget = translateTarget
    }

    init(settings: AppSettings) {
        self.init(sttProvider: settings.sttProvider, polishProvider: settings.polishProvider,
                  forceTraditional: settings.forceTraditional,
                  spaceBetweenCJKAndLatin: settings.spaceBetweenCJKAndLatin,
                  translateTarget: settings.translateTarget)
        punctuationRule = settings.punctuationRule
        punctuationLimit = settings.punctuationLimit
    }
}

/// audio file → STT → (LLM polish | rule-based cleanup) → dictionary replacements → zh-TW conversion → text.
///
/// `run(transcript:…)` starts after STT with a transcript that is already there (real-time
/// transcription); everything after STT is the same code for both entry points.
public struct DictationPipeline: Sendable {
    private let config: @Sendable () -> PipelineConfig
    private let dictionary: DictionaryStore
    private let makeSTT: @Sendable (STTProviderKind) throws -> any STTProvider
    private let makePolish: @Sendable (PolishProviderKind) throws -> (any PolishProvider)?

    public init(settings: AppSettings = .shared, keys: KeychainStore = .shared, dictionary: DictionaryStore = .shared) {
        self.init(config: { PipelineConfig(settings: settings) },
                  dictionary: dictionary,
                  makeSTT: { try STTFactory.make($0, keys: keys) },
                  makePolish: { try PolishFactory.make($0, keys: keys) })
    }

    /// Dependency-injected initializer used by tests.
    init(config: @escaping @Sendable () -> PipelineConfig,
         dictionary: DictionaryStore,
         makeSTT: @escaping @Sendable (STTProviderKind) throws -> any STTProvider,
         makePolish: @escaping @Sendable (PolishProviderKind) throws -> (any PolishProvider)?) {
        self.config = config
        self.dictionary = dictionary
        self.makeSTT = makeSTT
        self.makePolish = makePolish
    }

    public func run(audioFile: URL, request: DictationRequest) async throws -> PipelineResult {
        let config = config()
        let entries = dictionary.snapshot()
        let mode = Self.effectiveMode(request)
        // Fail before spending STT money if the mode cannot be served.
        let (llm, llmKind) = try resolveLLM(mode: mode, config: config)

        // 1. STT
        let stt = try makeSTT(config.sttProvider)
        let options = STTOptions(languageCode: config.languageCode, keyterms: Self.keyterms(from: entries))
        let sttStart = ContinuousClock.now
        let transcript: String
        do {
            transcript = try await stt.transcribe(audioFile: audioFile, options: options)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Self.normalizeCancellation(error)
        }
        let sttMillis = Self.millis(since: sttStart)
        return try await postProcess(transcript, sttMillis: sttMillis, usedRealtime: false, request: request,
                                     mode: mode, llm: llm, llmKind: llmKind, config: config, entries: entries)
    }

    /// The post-STT stages (polish or rule-based cleanup → dictionary → zh-TW → normalize) on a
    /// transcript obtained elsewhere, e.g. the final text of a real-time session. Same rules and
    /// errors as `run(audioFile:…)`, including `PolishError.requiresLLM` for translate / edit and
    /// `ProviderError.emptyResult`. `sttMillis` is reported as is (the caller measured it).
    public func run(transcript: String, request: DictationRequest, sttMillis: Int = 0) async throws -> PipelineResult {
        let config = config()
        let entries = dictionary.snapshot()
        let mode = Self.effectiveMode(request)
        let (llm, llmKind) = try resolveLLM(mode: mode, config: config)
        return try await postProcess(transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                                     sttMillis: sttMillis, usedRealtime: true, request: request, mode: mode,
                                     llm: llm, llmKind: llmKind, config: config, entries: entries)
    }

    /// The cheap, deterministic part of the output stage for text shown while speaking:
    /// Simplified → Traditional (Taiwan) and 台. No polish, dictionary or punctuation changes (they
    /// need the whole text). A few hundred characters convert in well under a millisecond once the
    /// dictionaries are loaded (`ZhTW.prewarm()`).
    public static func livePreview(_ text: String) -> String {
        ZhTW.preferCommonTai(ZhTW.toTraditionalTaiwan(text))
    }

    /// Translate and edit always need an LLM, but they do not need "AI 潤飾" to be switched on:
    /// that setting only decides whether plain dictation is polished. With polish off they use
    /// whichever LLM has a key.
    private func resolveLLM(mode: DictationMode, config: PipelineConfig) throws -> ((any PolishProvider)?, PolishProviderKind) {
        if mode == .dictate {
            // Dictation still works without the LLM.
            return (try? makePolish(config.polishProvider), config.polishProvider)
        }
        let preferred: [PolishProviderKind] = config.polishProvider == .off ? [] : [config.polishProvider]
        let candidates = preferred + [PolishProviderKind.groq, .anthropic].filter { !preferred.contains($0) }
        for kind in candidates {
            if let provider = try? makePolish(kind) { return (provider, kind) }
        }
        throw PolishError.requiresLLM(mode)
    }

    private func postProcess(_ transcript: String, sttMillis: Int, usedRealtime: Bool, request: DictationRequest,
                             mode: DictationMode, llm: (any PolishProvider)?, llmKind: PolishProviderKind,
                             config: PipelineConfig, entries: [DictionaryEntry]) async throws -> PipelineResult {
        try Self.checkCancellation()
        guard CleanupRules.hasContent(transcript) else { throw ProviderError.emptyResult }

        // 2. Polish
        let context = PolishContext(mode: mode, dictionary: entries, selectedText: request.selectedText,
                                    translateTarget: config.translateTarget, fieldHint: request.fieldHint,
                                    spaceBetweenCJKAndLatin: config.spaceBetweenCJKAndLatin)
        let polishStart = ContinuousClock.now
        var text: String
        var usedPolish = PolishProviderKind.off
        if let llm, mode != .dictate || Self.unitCount(transcript) > config.shortTranscriptLimit {
            do {
                // Short dictations must stay snappy (4.5 s), but a 15-minute recording is several
                // thousand characters and the LLM needs proportionally longer to write it out.
                let deadline = min(150, config.polishTimeout + Double(Self.unitCount(transcript)) / 40)
                text = try await ProviderHTTP.withDeadline(seconds: deadline) {
                    try await llm.polish(transcript, context: context)
                }
                usedPolish = llmKind
            } catch {
                let error = Self.normalizeCancellation(error)
                if case ProviderError.cancelled = error { throw error }
                // Dictation falls back to rule-based cleanup. Edit / translate must not: the fallback
                // would replace the user's selection with the spoken instruction, or insert untranslated text.
                guard mode == .dictate else { throw error }
                text = RuleBasedCleanup.clean(transcript)
            }
        } else {
            text = RuleBasedCleanup.clean(transcript)
        }
        let polishMillis = Self.millis(since: polishStart)
        try Self.checkCancellation()

        // 3. Dictionary, 4. zh-TW
        let convert = config.forceTraditional && !(mode == .translate && !Self.isChineseTarget(config.translateTarget))
        text = Self.outputStage(text, replacements: dictionary.applyReplacements(to:), convertToTraditional: convert,
                                spaceBetweenCJKAndLatin: config.spaceBetweenCJKAndLatin)
        // A short message ("好", "我到了", "OK thanks") reads as curt with a full stop. 說話改字
        // rewrites existing text, whose own punctuation is left alone.
        if mode != .edit {
            text = PunctuationStyler.apply(text, rule: config.punctuationRule, limit: config.punctuationLimit)
        }
        guard !text.isEmpty else { throw ProviderError.emptyResult }

        return PipelineResult(rawTranscript: transcript, finalText: text, sttMillis: sttMillis,
                              polishMillis: polishMillis, sttProvider: config.sttProvider,
                              polishProvider: usedPolish, usedRealtime: usedRealtime)
    }

    // MARK: Helpers

    /// Dictionary replacements → Simplified → Traditional (Taiwan) with 台 → punctuation and
    /// spacing normalization → trim. Shared with file transcription (`TranscriptPostProcessor`) so
    /// both write text the same way.
    static func outputStage(_ text: String, replacements: (String) -> String, convertToTraditional: Bool,
                            spaceBetweenCJKAndLatin: Bool) -> String {
        var text = replacements(text)
        if convertToTraditional {
            text = ZhTW.toTraditionalTaiwan(text)
            text = ZhTW.preferCommonTai(text)
        }
        text = ZhTW.normalize(text, spaceBetweenCJKAndLatin: spaceBetweenCJKAndLatin)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Edit without a selection is plain dictation.
    static func effectiveMode(_ request: DictationRequest) -> DictationMode {
        if request.mode == .edit,
           (request.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .dictate
        }
        return request.mode
    }

    /// Correct spellings only; `soundsLike` variants are what we *don't* want STT to produce.
    static func keyterms(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }

    /// CJK characters count one each, runs of Latin letters/digits count as one word.
    static func unitCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80, CharacterSet.letters.contains(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    /// Whether a translate target is a Chinese variety that should still be forced to Traditional.
    /// An explicit Simplified target is respected.
    static func isChineseTarget(_ target: String) -> Bool {
        let t = target.lowercased()
        if t.contains("simplified") || t.contains("简") || t.contains("簡") || t.hasPrefix("zh-cn") || t.hasPrefix("zh-hans") {
            return false
        }
        return t.contains("chinese") || t.contains("中文") || t.contains("漢語") || t.contains("華語")
            || t.contains("國語") || t.contains("mandarin") || t.contains("cantonese") || t.contains("粵")
            || t.contains("繁") || t == "zh" || t.hasPrefix("zh-") || t.hasPrefix("zh_")
    }

    private static func millis(since start: ContinuousClock.Instant) -> Int {
        Int(((ContinuousClock.now - start) / .milliseconds(1)).rounded())
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw ProviderError.cancelled }
    }

    private static func normalizeCancellation(_ error: Error) -> Error {
        if error is CancellationError { return ProviderError.cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return ProviderError.cancelled }
        if Task.isCancelled { return ProviderError.cancelled }
        return error
    }
}
