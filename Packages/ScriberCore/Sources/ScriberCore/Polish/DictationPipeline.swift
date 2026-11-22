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
    /// The mode that ran (`ResolvedModeConfig.modeID`).
    public var modeID: String
    /// What the AI did (`.dictation` for rule-based cleanup too).
    public var task: PromptKind
    /// What the caller should do with `finalText` (PRD §4) and which key to press after pasting.
    public var output: ModeOutput
    public var autoSend: ModeAutoSend

    public init(rawTranscript: String, finalText: String, sttMillis: Int, polishMillis: Int,
                sttProvider: STTProviderKind, polishProvider: PolishProviderKind, usedRealtime: Bool = false,
                modeID: String = BuiltInModeID.dictate.rawValue, task: PromptKind = .dictation,
                output: ModeOutput = .paste, autoSend: ModeAutoSend = .none) {
        self.rawTranscript = rawTranscript; self.finalText = finalText
        self.sttMillis = sttMillis; self.polishMillis = polishMillis
        self.sttProvider = sttProvider; self.polishProvider = polishProvider
        self.usedRealtime = usedRealtime
        self.modeID = modeID; self.task = task; self.output = output; self.autoSend = autoSend
    }
}

/// The pre-modes name of the global settings snapshot the pipeline starts from.
typealias PipelineConfig = ModeDefaults

/// audio file → STT → (LLM | rule-based cleanup) → dictionary replacements → zh-TW conversion → text.
///
/// Every run follows a `ResolvedModeConfig`: the request's mode (see `DictationRequest.modeID`)
/// resolved against the global settings and the prompt library (`ModeResolver`). Callers can
/// resolve themselves (`resolve(_:)`) and pass the result, e.g. to decide real-time transcription
/// or the output before the run; otherwise each run resolves on its own.
///
/// `run(transcript:…)` starts after STT with a transcript that is already there (real-time
/// transcription); everything after STT is the same code for both entry points.
public struct DictationPipeline: Sendable {
    private let config: @Sendable () -> ModeDefaults
    private let modes: @Sendable () -> [DictationModeConfig]
    private let prompts: @Sendable () -> [PromptTemplate]
    private let dictionary: DictionaryStore
    private let makeSTT: @Sendable (STTProviderKind) throws -> any STTProvider
    private let makePolish: @Sendable (PolishProviderKind) throws -> (any PolishProvider)?
    /// Diagnostics: mode id, task, provider kinds, context kinds and their lengths. Never content.
    private let log: @Sendable (String) -> Void

    public init(settings: AppSettings = .shared, keys: KeychainStore = .shared, dictionary: DictionaryStore = .shared,
                modes: ModeStore = .shared, prompts: PromptLibrary = .shared) {
        self.init(config: { ModeDefaults(settings: settings) },
                  modes: { modes.snapshot() },
                  prompts: { prompts.snapshot() },
                  dictionary: dictionary,
                  makeSTT: { try STTFactory.make($0, keys: keys) },
                  makePolish: { try PolishFactory.make($0, keys: keys) },
                  log: { DiagLog.log("pipe", $0) })
    }

    /// Dependency-injected initializer used by tests: the shipped modes and prompts, no log.
    init(config: @escaping @Sendable () -> PipelineConfig,
         dictionary: DictionaryStore,
         makeSTT: @escaping @Sendable (STTProviderKind) throws -> any STTProvider,
         makePolish: @escaping @Sendable (PolishProviderKind) throws -> (any PolishProvider)?) {
        self.init(config: config, modes: { DictationModeConfig.builtIns }, prompts: { PromptLibrary.builtIns },
                  dictionary: dictionary, makeSTT: makeSTT, makePolish: makePolish, log: { _ in })
    }

    init(config: @escaping @Sendable () -> ModeDefaults,
         modes: @escaping @Sendable () -> [DictationModeConfig],
         prompts: @escaping @Sendable () -> [PromptTemplate],
         dictionary: DictionaryStore,
         makeSTT: @escaping @Sendable (STTProviderKind) throws -> any STTProvider,
         makePolish: @escaping @Sendable (PolishProviderKind) throws -> (any PolishProvider)?,
         log: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.modes = modes
        self.prompts = prompts
        self.dictionary = dictionary
        self.makeSTT = makeSTT
        self.makePolish = makePolish
        self.log = log
    }

    /// The configuration `request` runs with right now (selection known).
    public func resolve(_ request: DictationRequest) -> ResolvedModeConfig {
        ModeResolver.resolve(request, modes: modes(), prompts: prompts(), defaults: config())
    }

    public func run(audioFile: URL, request: DictationRequest) async throws -> PipelineResult {
        try await run(audioFile: audioFile, request: request, resolved: resolve(request))
    }

    /// Runs with a configuration resolved earlier (`resolve(_:)`, with the final request).
    public func run(audioFile: URL, request: DictationRequest, resolved: ResolvedModeConfig) async throws -> PipelineResult {
        let entries = dictionary.snapshot()
        // Fail before spending STT money if the mode cannot be served.
        let (llm, llmKind) = try resolveLLM(resolved)
        logStart(resolved, request: request, llmKind: llm == nil ? nil : llmKind)

        // 1. STT
        let stt = try makeSTT(resolved.sttProvider)
        let options = STTOptions(languageCode: resolved.languageCode, keyterms: Self.keyterms(from: entries))
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
                                     resolved: resolved, llm: llm, llmKind: llmKind, entries: entries)
    }

    /// The post-STT stages (polish or rule-based cleanup → dictionary → zh-TW → normalize) on a
    /// transcript obtained elsewhere, e.g. the final text of a real-time session. Same rules and
    /// errors as `run(audioFile:…)`, including `PolishError.requiresLLM` for translate / edit and
    /// `ProviderError.emptyResult`. `sttMillis` is reported as is (the caller measured it).
    public func run(transcript: String, request: DictationRequest, sttMillis: Int = 0) async throws -> PipelineResult {
        try await run(transcript: transcript, request: request, resolved: resolve(request), sttMillis: sttMillis)
    }

    public func run(transcript: String, request: DictationRequest, resolved: ResolvedModeConfig,
                    sttMillis: Int = 0) async throws -> PipelineResult {
        let entries = dictionary.snapshot()
        let (llm, llmKind) = try resolveLLM(resolved)
        logStart(resolved, request: request, llmKind: llm == nil ? nil : llmKind)
        return try await postProcess(transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                                     sttMillis: sttMillis, usedRealtime: true, request: request,
                                     resolved: resolved, llm: llm, llmKind: llmKind, entries: entries)
    }

    /// The cheap, deterministic part of the output stage for text shown while speaking:
    /// Simplified → Traditional (Taiwan) and 台. No polish, dictionary or punctuation changes (they
    /// need the whole text). A few hundred characters convert in well under a millisecond once the
    /// dictionaries are loaded (`ZhTW.prewarm()`).
    public static func livePreview(_ text: String) -> String {
        ZhTW.preferCommonTai(ZhTW.toTraditionalTaiwan(text))
    }

    /// The first candidate with a key. Translate and edit (any `required` LLM) do not need
    /// "AI 潤飾" to be switched on: that setting only decides whether plain dictation is polished.
    private func resolveLLM(_ resolved: ResolvedModeConfig) throws -> ((any PolishProvider)?, PolishProviderKind) {
        guard let llm = resolved.llm else { return (nil, .off) }
        for kind in llm.candidates {
            if let provider = try? makePolish(kind) { return (provider, kind) }
        }
        // Plain dictation still works without the LLM.
        guard llm.required else { return (nil, llm.candidates.first ?? .off) }
        throw PolishError.requiresLLM(resolved.legacyMode)
    }

    private func postProcess(_ transcript: String, sttMillis: Int, usedRealtime: Bool, request: DictationRequest,
                             resolved: ResolvedModeConfig, llm: (any PolishProvider)?, llmKind: PolishProviderKind,
                             entries: [DictionaryEntry]) async throws -> PipelineResult {
        try Self.checkCancellation()
        guard CleanupRules.hasContent(transcript) else { throw ProviderError.emptyResult }

        // 2. Polish
        let context = polishContext(resolved, request: request, entries: entries)
        let polishStart = ContinuousClock.now
        var text: String
        var usedPolish = PolishProviderKind.off
        if let llm, !resolved.skipsLLMForShortTranscripts || Self.unitCount(transcript) > resolved.shortTranscriptLimit {
            do {
                // Short dictations must stay snappy (4.5 s), but a 15-minute recording is several
                // thousand characters and the LLM needs proportionally longer to write it out.
                let deadline = min(150, resolved.polishTimeout + Double(Self.unitCount(transcript)) / 40)
                text = try await ProviderHTTP.withDeadline(seconds: deadline) {
                    try await llm.polish(transcript, context: context)
                }
                usedPolish = llmKind
            } catch {
                let error = Self.normalizeCancellation(error)
                if case ProviderError.cancelled = error { throw error }
                // Dictation falls back to rule-based cleanup. The others must not: the fallback would
                // replace the user's selection with the spoken instruction, or insert untranslated text.
                guard resolved.fallsBackToRuleBasedCleanup else { throw error }
                text = RuleBasedCleanup.clean(transcript)
            }
        } else {
            text = RuleBasedCleanup.clean(transcript)
        }
        let polishMillis = Self.millis(since: polishStart)
        try Self.checkCancellation()

        // 3. Dictionary, 4. zh-TW
        text = Self.outputStage(text, replacements: dictionary.applyReplacements(to:),
                                convertToTraditional: resolved.convertsToTraditional,
                                spaceBetweenCJKAndLatin: resolved.spaceBetweenCJKAndLatin)
        // A short message ("好", "我到了", "OK thanks") reads as curt with a full stop. 說話改字
        // rewrites existing text, whose own punctuation is left alone.
        if resolved.appliesPunctuationRule {
            text = PunctuationStyler.apply(text, rule: resolved.punctuationRule, limit: resolved.punctuationLimit)
        }
        guard !text.isEmpty else { throw ProviderError.emptyResult }

        return PipelineResult(rawTranscript: transcript, finalText: text, sttMillis: sttMillis,
                              polishMillis: polishMillis, sttProvider: resolved.sttProvider,
                              polishProvider: usedPolish, usedRealtime: usedRealtime,
                              modeID: resolved.modeID, task: resolved.task, output: resolved.output,
                              autoSend: resolved.autoSend)
    }

    /// What the LLM gets. Context the mode does not allow is left out here already, not only in the prompt.
    func polishContext(_ resolved: ResolvedModeConfig, request: DictationRequest, entries: [DictionaryEntry]) -> PolishContext {
        let flags = resolved.context
        return PolishContext(mode: resolved.legacyMode, dictionary: entries,
                             selectedText: flags.selectedText ? request.selectedText : nil,
                             translateTarget: resolved.translateTarget, fieldHint: request.fieldHint,
                             spaceBetweenCJKAndLatin: resolved.spaceBetweenCJKAndLatin,
                             prompt: resolved.llm?.prompt, contextFlags: flags,
                             clipboardText: flags.clipboard ? request.clipboardText : nil,
                             appName: flags.appName ? request.appName : nil)
    }

    /// One content-free line per run: which mode, what it does, which context kinds go along and
    /// how long they are. Never the transcript, selection, clipboard, prompt text or mode name.
    private func logStart(_ resolved: ResolvedModeConfig, request: DictationRequest, llmKind: PolishProviderKind?) {
        var line = "mode id=\(resolved.modeID)"
        if resolved.requestedModeID != resolved.modeID { line += " requested=\(resolved.requestedModeID)" }
        line += " task=\(resolved.task.rawValue) llm=\(llmKind?.rawValue ?? "off")"
        if let prompt = resolved.llm?.prompt {
            line += " prompt=\(prompt.builtInID?.rawValue ?? "custom")\(prompt.isPristineBuiltIn ? "" : "*")"
        }
        line += " output=\(resolved.output.rawValue)"
        let context = polishContext(resolved, request: request, entries: [])
        var kinds: [String] = []
        let selected = (context.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if resolved.llm != nil, !selected.isEmpty { kinds.append("selected:\(selected.count)") }
        if let clip = context.clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
            kinds.append("clipboard:\(min(clip.count, PolishPrompt.contextCharacterLimit))")
        }
        if let app = context.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            kinds.append("app:\(min(app.count, PolishPrompt.appNameLimit))")
        }
        line += " context=\(kinds.isEmpty ? "-" : kinds.joined(separator: ","))"
        log(line)
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
