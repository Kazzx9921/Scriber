import XCTest
@testable import ScriberCore
import ScriberShared

/// Thread-safe call log for the pipeline stubs.
final class PipelineCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _sttOptions: [STTOptions] = []
    private var _polishCalls: [(String, PolishContext)] = []

    func recordSTT(_ options: STTOptions) { lock.lock(); _sttOptions.append(options); lock.unlock() }
    func recordPolish(_ text: String, _ context: PolishContext) { lock.lock(); _polishCalls.append((text, context)); lock.unlock() }
    var sttOptions: [STTOptions] { lock.lock(); defer { lock.unlock() }; return _sttOptions }
    var polishCalls: [(String, PolishContext)] { lock.lock(); defer { lock.unlock() }; return _polishCalls }
}

struct PipelineStubSTT: STTProvider {
    var transcript: String
    var delay: TimeInterval = 0
    var log: PipelineCallLog

    func transcribe(audioFile: URL, options: STTOptions) async throws -> String {
        log.recordSTT(options)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return transcript
    }
}

struct PipelineStubPolish: PolishProvider {
    var log: PipelineCallLog
    var delay: TimeInterval = 0
    var result: @Sendable (String, PolishContext) throws -> String

    func polish(_ transcript: String, context: PolishContext) async throws -> String {
        log.recordPolish(transcript, context)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try result(transcript, context)
    }
}

final class PipelineTests: XCTestCase {
    private var audio: URL!
    private var dictionaryURL: URL!

    override func setUpWithError() throws {
        audio = try makeTempAudioFile()
        dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberPipelineTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dictionaryURL)
    }

    private func config(polish: PolishProviderKind = .off, stt: STTProviderKind = .elevenLabsScribe,
                        target: String = "English", polishTimeout: TimeInterval = 4.5) -> PipelineConfig {
        var c = PipelineConfig(sttProvider: stt, polishProvider: polish, forceTraditional: true,
                               spaceBetweenCJKAndLatin: true, translateTarget: target)
        c.polishTimeout = polishTimeout
        return c
    }

    private func pipeline(_ config: PipelineConfig, transcript: String, sttDelay: TimeInterval = 0,
                          dictionary: DictionaryStore? = nil, log: PipelineCallLog,
                          polish: PipelineStubPolish? = nil,
                          makePolishError: Error? = nil) -> DictationPipeline {
        let store = dictionary ?? DictionaryStore(fileURL: dictionaryURL)
        return DictationPipeline(
            config: { config },
            dictionary: store,
            makeSTT: { _ in PipelineStubSTT(transcript: transcript, delay: sttDelay, log: log) },
            makePolish: { kind in
                if let makePolishError { throw makePolishError }
                return kind == .off ? nil : polish
            })
    }

    /// What the tail of the pipeline does to cleaned text (agent B owns ZhTW; compute through it).
    private func tail(_ text: String, space: Bool = true) -> String {
        ZhTW.normalize(ZhTW.toTraditionalTaiwan(text), spaceBetweenCJKAndLatin: space)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func echoPolish(_ log: PipelineCallLog, _ output: String) -> PipelineStubPolish {
        PipelineStubPolish(log: log) { _, _ in output }
    }

    // MARK: Default (no LLM) path

    func testPolishOffUsesRuleBasedCleanup() async throws {
        let log = PipelineCallLog()
        let raw = "嗯，我我我覺得這個方案可以。。"
        let result = try await pipeline(config(), transcript: raw, log: log)
            .run(audioFile: audio, request: DictationRequest())
        XCTAssertEqual(result.rawTranscript, raw)
        XCTAssertEqual(result.finalText, tail("我覺得這個方案可以"))
        XCTAssertEqual(result.polishProvider, .off)
        XCTAssertEqual(result.sttProvider, .elevenLabsScribe)
        XCTAssertTrue(log.polishCalls.isEmpty)
        XCTAssertEqual(log.sttOptions.first?.languageCode, "zh")
    }

    func testEmptyTranscriptThrows() async {
        for raw in ["", "   \n", "，。"] {
            let log = PipelineCallLog()
            do {
                _ = try await pipeline(config(), transcript: raw, log: log).run(audioFile: audio, request: DictationRequest())
                XCTFail("expected emptyResult for \(raw.debugDescription)")
            } catch {
                guard case ProviderError.emptyResult = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testFillerOnlyTranscriptIsKept() async throws {
        let result = try await pipeline(config(), transcript: "嗯嗯", log: PipelineCallLog())
            .run(audioFile: audio, request: DictationRequest())
        XCTAssertEqual(result.finalText, tail("嗯嗯"))
    }

    func testSTTFactoryErrorPropagates() async {
        let p = DictationPipeline(config: { self.config() }, dictionary: DictionaryStore(fileURL: dictionaryURL),
                                  makeSTT: { _ in throw ProviderError.missingAPIKey(.elevenLabs) },
                                  makePolish: { _ in nil })
        do {
            _ = try await p.run(audioFile: audio, request: DictationRequest())
            XCTFail("expected error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.errorDescription, "還沒設定 ElevenLabs 的 API key，請到設定填寫")
        }
    }

    // MARK: LLM path

    func testLLMPolishIsUsed() async throws {
        let log = PipelineCallLog()
        let raw = "嗯那個我們明天呃不對後天下午開會"
        let p = pipeline(config(polish: .anthropic), transcript: raw, log: log,
                         polish: echoPolish(log, "我們後天下午開會。"))
        let result = try await p.run(audioFile: audio, request: DictationRequest(fieldHint: .chat))
        XCTAssertEqual(result.finalText, tail("我們後天下午開會"))
        XCTAssertEqual(result.polishProvider, .anthropic)
        XCTAssertEqual(result.rawTranscript, raw)
        let call = try XCTUnwrap(log.polishCalls.first)
        XCTAssertEqual(call.0, raw, "LLM gets the raw transcript, not the rule-cleaned one")
        XCTAssertEqual(call.1.mode, .dictate)
        XCTAssertEqual(call.1.fieldHint, .chat)
        XCTAssertTrue(call.1.spaceBetweenCJKAndLatin)
    }

    func testShortTranscriptSkipsLLM() async throws {
        let log = PipelineCallLog()
        for raw in ["好的謝謝", "OK 收到", "嗯，明天見"] {
            let result = try await pipeline(config(polish: .groq), transcript: raw, log: log,
                                            polish: echoPolish(log, "不該被呼叫"))
                .run(audioFile: audio, request: DictationRequest())
            XCTAssertEqual(result.finalText, tail(RuleBasedCleanup.clean(raw)))
            XCTAssertEqual(result.polishProvider, .off)
        }
        XCTAssertTrue(log.polishCalls.isEmpty)
    }

    func testLLMErrorFallsBackToRules() async throws {
        let log = PipelineCallLog()
        let raw = "嗯，我我我覺得我們明天可以再討論一次"
        let failing = PipelineStubPolish(log: log) { _, _ in throw ProviderError.http(status: 500, message: "boom") }
        let result = try await pipeline(config(polish: .groq), transcript: raw, log: log, polish: failing)
            .run(audioFile: audio, request: DictationRequest())
        XCTAssertEqual(result.finalText, tail("我覺得我們明天可以再討論一次"))
        XCTAssertEqual(result.polishProvider, .off)
        XCTAssertEqual(log.polishCalls.count, 1)
    }

    func testLLMTimeoutFallsBackQuickly() async throws {
        let log = PipelineCallLog()
        let raw = "然後然後我們下禮拜再約時間討論細節"
        let slow = PipelineStubPolish(log: log, delay: 5) { _, _ in "太慢了" }
        let start = Date()
        let result = try await pipeline(config(polish: .anthropic, polishTimeout: 0.2), transcript: raw, log: log, polish: slow)
            .run(audioFile: audio, request: DictationRequest())
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(result.finalText, tail("然後我們下禮拜再約時間討論細節"))
        XCTAssertEqual(result.polishProvider, .off)
    }

    func testMissingLLMKeyStillDictates() async throws {
        let raw = "我們明天下午三點在公司見面"
        let result = try await pipeline(config(polish: .groq), transcript: raw, log: PipelineCallLog(),
                                        makePolishError: ProviderError.missingAPIKey(.groq))
            .run(audioFile: audio, request: DictationRequest())
        XCTAssertEqual(result.finalText, tail(raw))
        XCTAssertEqual(result.polishProvider, .off)
    }

    // MARK: Translate / edit

    func testTranslateAndEditRequireLLM() async {
        for request in [DictationRequest(mode: .translate), DictationRequest(mode: .edit, selectedText: "原文")] {
            let log = PipelineCallLog()
            do {
                _ = try await pipeline(config(polish: .off), transcript: "幫我翻成英文", log: log)
                    .run(audioFile: audio, request: request)
                XCTFail("expected requiresLLM")
            } catch {
                XCTAssertEqual(error as? PolishError, .requiresLLM(request.mode))
                XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("API key") == true)
            }
            XCTAssertTrue(log.sttOptions.isEmpty, "no STT call when the mode can't be served")
        }
    }

    func testTranslateWorksWithPolishOffWhenAnLLMKeyExists() async throws {
        let log = PipelineCallLog()
        let result = try await pipeline(config(polish: .off), transcript: "明天下午三點開會", log: log,
                                        polish: PipelineStubPolish(log: log, result: { _, _ in "Meeting at 3 pm tomorrow" }))
            .run(audioFile: audio, request: DictationRequest(mode: .translate))
        XCTAssertEqual(result.finalText, "Meeting at 3 pm tomorrow")
        XCTAssertEqual(result.polishProvider, .groq, "falls back to the first LLM that has a key")
    }

    func testTranslateMissingKeyFailsBeforeSTT() async {
        let log = PipelineCallLog()
        do {
            _ = try await pipeline(config(polish: .anthropic), transcript: "你好", log: log,
                                   makePolishError: ProviderError.missingAPIKey(.anthropic))
                .run(audioFile: audio, request: DictationRequest(mode: .translate))
            XCTFail("expected error")
        } catch {
            // With no usable LLM key at all, translate reports that an LLM key is needed.
            XCTAssertEqual(error as? PolishError, .requiresLLM(.translate), "\(error)")
        }
        XCTAssertTrue(log.sttOptions.isEmpty)
    }

    func testTranslateUsesLLMEvenForShortInput() async throws {
        let log = PipelineCallLog()
        let result = try await pipeline(config(polish: .groq, target: "English"), transcript: "你好", log: log,
                                        polish: echoPolish(log, "Hello"))
            .run(audioFile: audio, request: DictationRequest(mode: .translate))
        XCTAssertEqual(result.finalText, ZhTW.normalize("Hello", spaceBetweenCJKAndLatin: true))
        XCTAssertEqual(result.polishProvider, .groq)
        XCTAssertEqual(log.polishCalls.first?.1.mode, .translate)
        XCTAssertEqual(log.polishCalls.first?.1.translateTarget, "English")
    }

    func testTranslateFailureDoesNotFallBack() async {
        let log = PipelineCallLog()
        let failing = PipelineStubPolish(log: log) { _, _ in throw ProviderError.http(status: 429, message: "") }
        do {
            _ = try await pipeline(config(polish: .groq), transcript: "幫我問他明天有沒有空", log: log, polish: failing)
                .run(audioFile: audio, request: DictationRequest(mode: .translate))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.errorDescription, "用量或頻率超過上限，請稍後再試")
        }
    }

    func testEditPassesSelectionAndDoesNotFallBack() async throws {
        let log = PipelineCallLog()
        let selection = "明天下午三點開會，請大家準時。"
        let ok = try await pipeline(config(polish: .anthropic), transcript: "改成比較正式", log: log,
                                    polish: echoPolish(log, "謹訂於明日下午三時召開會議，敬請準時出席。"))
            .run(audioFile: audio, request: DictationRequest(mode: .edit, selectedText: selection))
        XCTAssertEqual(ok.finalText, tail("謹訂於明日下午三時召開會議，敬請準時出席。"))
        XCTAssertEqual(log.polishCalls.first?.1.mode, .edit)
        XCTAssertEqual(log.polishCalls.first?.1.selectedText, selection)

        let failing = PipelineStubPolish(log: log) { _, _ in throw PolishError.invalidOutput }
        do {
            _ = try await pipeline(config(polish: .anthropic), transcript: "改成比較正式", log: log, polish: failing)
                .run(audioFile: audio, request: DictationRequest(mode: .edit, selectedText: selection))
            XCTFail("edit must not fall back to inserting the spoken instruction")
        } catch {
            XCTAssertEqual(error as? PolishError, .invalidOutput)
        }
    }

    func testEditWithoutSelectionIsDictation() async throws {
        let log = PipelineCallLog()
        let result = try await pipeline(config(polish: .off), transcript: "嗯，我們明天見", log: log)
            .run(audioFile: audio, request: DictationRequest(mode: .edit, selectedText: "   "))
        XCTAssertEqual(result.finalText, tail("我們明天見"))
    }

    func testChineseTargetDetection() {
        XCTAssertFalse(DictationPipeline.isChineseTarget("English"))
        XCTAssertFalse(DictationPipeline.isChineseTarget("日本語"))
        XCTAssertFalse(DictationPipeline.isChineseTarget("Simplified Chinese"))
        XCTAssertFalse(DictationPipeline.isChineseTarget("简体中文"))
        XCTAssertTrue(DictationPipeline.isChineseTarget("Traditional Chinese"))
        XCTAssertTrue(DictationPipeline.isChineseTarget("繁體中文"))
        XCTAssertTrue(DictationPipeline.isChineseTarget("中文"))
        XCTAssertTrue(DictationPipeline.isChineseTarget("zh-TW"))
    }

    // MARK: Dictionary, timing, cancellation

    func testDictionaryTermsBecomeKeyterms() async throws {
        let store = DictionaryStore(fileURL: dictionaryURL)
        store.add(DictionaryEntry(term: "Claude Code", soundsLike: ["cloud code"]))
        store.add(DictionaryEntry(term: "鹿野"))
        store.add(DictionaryEntry(term: "claude code"))
        try XCTSkipIf(store.snapshot().isEmpty, "DictionaryStore persistence not implemented yet")

        let log = PipelineCallLog()
        _ = try await pipeline(config(), transcript: "我在用 cloud code 寫程式", dictionary: store, log: log)
            .run(audioFile: audio, request: DictationRequest())
        XCTAssertEqual(log.sttOptions.first?.keyterms, ["Claude Code", "鹿野"])
    }

    func testKeytermExtraction() {
        let entries = [DictionaryEntry(term: " Claude Code ", soundsLike: ["cloud code"]),
                       DictionaryEntry(term: ""), DictionaryEntry(term: "CLAUDE CODE"), DictionaryEntry(term: "鹿野")]
        XCTAssertEqual(DictationPipeline.keyterms(from: entries), ["Claude Code", "鹿野"])
    }

    func testTimingsAreRecorded() async throws {
        let result = try await pipeline(config(), transcript: "我們明天見", sttDelay: 0.05, log: PipelineCallLog())
            .run(audioFile: audio, request: DictationRequest())
        XCTAssertGreaterThanOrEqual(result.sttMillis, 40)
        XCTAssertGreaterThanOrEqual(result.polishMillis, 0)
    }

    func testCancellationDuringSTT() async throws {
        let p = pipeline(config(), transcript: "我們明天見", sttDelay: 3, log: PipelineCallLog())
        let task = Task { try await p.run(audioFile: audio, request: DictationRequest()) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            guard case ProviderError.cancelled = error else { return XCTFail("\(error)") }
        }
    }

    func testCancellationDuringPolishIsNotSwallowed() async throws {
        let log = PipelineCallLog()
        let slow = PipelineStubPolish(log: log, delay: 3) { _, _ in "太慢了" }
        let p = pipeline(config(polish: .groq), transcript: "我們下禮拜再約時間討論細節", log: log, polish: slow)
        let task = Task { try await p.run(audioFile: audio, request: DictationRequest()) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation, not a rule-based fallback")
        } catch {
            guard case ProviderError.cancelled = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Transcript entry point (real-time)

    /// A real-time transcript goes through exactly the same stages as an uploaded clip.
    func testTranscriptPathMatchesTheAudioPath() async throws {
        let store = DictionaryStore(fileURL: dictionaryURL)
        store.add(DictionaryEntry(term: "Claude Code", soundsLike: ["cloud code"]))
        for (polish, raw) in [(PolishProviderKind.off, "嗯，我今天用 cloud code 写了一个程序，部署到臺北的服务器"),
                              (.groq, "那个我们明天下午三点在台湾的办公室开会讨论 cloud code")] {
            let log = PipelineCallLog()
            let p = pipeline(config(polish: polish), transcript: raw, dictionary: store, log: log,
                             polish: PipelineStubPolish(log: log) { text, _ in text + "。" })
            let fromAudio = try await p.run(audioFile: audio, request: DictationRequest())
            let fromTranscript = try await p.run(transcript: raw, request: DictationRequest(), sttMillis: 123)
            XCTAssertEqual(fromTranscript.finalText, fromAudio.finalText, "\(polish)")
            XCTAssertEqual(fromTranscript.rawTranscript, raw)
            XCTAssertEqual(fromTranscript.polishProvider, fromAudio.polishProvider)
            XCTAssertEqual(fromTranscript.sttMillis, 123)
            XCTAssertTrue(fromTranscript.usedRealtime)
            XCTAssertFalse(fromAudio.usedRealtime)
            XCTAssertEqual(log.sttOptions.count, 1, "the transcript path never calls STT")
            XCTAssertFalse(ZhTW.containsSimplified(fromTranscript.finalText))
            XCTAssertFalse(fromTranscript.finalText.contains("臺"))
            XCTAssertTrue(fromTranscript.finalText.contains("Claude Code"))
        }
    }

    func testTranscriptPathKeepsTheModeRules() async throws {
        let log = PipelineCallLog()
        do {
            _ = try await pipeline(config(polish: .off), transcript: "", log: log)
                .run(transcript: "翻成英文", request: DictationRequest(mode: .translate))
            XCTFail("expected requiresLLM")
        } catch {
            XCTAssertEqual(error as? PolishError, .requiresLLM(.translate))
        }
        let translated = try await pipeline(config(polish: .groq), transcript: "", log: log,
                                            polish: echoPolish(log, "Hello"))
            .run(transcript: "你好", request: DictationRequest(mode: .translate))
        XCTAssertEqual(translated.finalText, "Hello")
        XCTAssertEqual(log.polishCalls.last?.1.mode, .translate)

        for empty in ["", "  ", "。"] {
            do {
                _ = try await pipeline(config(), transcript: "", log: log).run(transcript: empty, request: DictationRequest())
                XCTFail("expected emptyResult")
            } catch {
                guard case ProviderError.emptyResult = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testUnitCount() {
        XCTAssertEqual(DictationPipeline.unitCount("好的謝謝"), 4)
        XCTAssertEqual(DictationPipeline.unitCount("OK 收到"), 3)
        XCTAssertEqual(DictationPipeline.unitCount("push 了一個 PR"), 5)
        XCTAssertEqual(DictationPipeline.unitCount("，。！"), 0)
        XCTAssertEqual(DictationPipeline.unitCount("我們明天下午開會"), 8)
    }
}
