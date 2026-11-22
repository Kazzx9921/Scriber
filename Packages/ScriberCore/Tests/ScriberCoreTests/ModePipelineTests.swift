import XCTest
@testable import ScriberCore
import ScriberShared

/// The pipeline running modes other than the three pre-modes ones, and what it logs.
final class ModePipelineTests: XCTestCase {
    private var audio: URL!
    private var dictionaryURL: URL!

    override func setUpWithError() throws {
        audio = try makeTempAudioFile()
        dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberModePipeline-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dictionaryURL)
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        private var _engines: [STTProviderKind] = []
        func add(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }
        func engine(_ kind: STTProviderKind) { lock.lock(); _engines.append(kind); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        var engines: [STTProviderKind] { lock.lock(); defer { lock.unlock() }; return _engines }
    }

    private func pipeline(polish: PolishProviderKind = .off, keys: Set<PolishProviderKind> = [.groq],
                          modes: [DictationModeConfig] = DictationModeConfig.builtIns,
                          prompts: [PromptTemplate] = PromptLibrary.builtIns,
                          transcript: String, calls: PipelineCallLog, log: Log = Log(),
                          output: @escaping @Sendable (String, PolishContext) throws -> String = { text, _ in text }) -> DictationPipeline {
        let defaults = ModeDefaults(sttProvider: .elevenLabsScribe, polishProvider: polish, forceTraditional: true,
                                    spaceBetweenCJKAndLatin: true, translateTarget: "English")
        return DictationPipeline(
            config: { defaults }, modes: { modes }, prompts: { prompts },
            dictionary: DictionaryStore(fileURL: dictionaryURL),
            makeSTT: { kind in log.engine(kind); return PipelineStubSTT(transcript: transcript, log: calls) },
            makePolish: { kind in
                guard kind != .off else { return nil }
                guard keys.contains(kind) else { throw ProviderError.missingAPIKey(kind == .groq ? .groq : .anthropic) }
                return PipelineStubPolish(log: calls, result: output)
            },
            log: { log.add($0) })
    }

    // MARK: 潤飾 / Email

    func testPolishModeAlwaysPolishesWithAnyKey() async throws {
        let calls = PipelineCallLog()
        let raw = "嗯我們明天下午三點在公司開會討論新的專案"
        let result = try await pipeline(polish: .off, transcript: raw, calls: calls) { _, _ in "我們明天下午三點在公司開會，討論新的專案。" }
            .run(audioFile: audio, request: DictationRequest(modeID: BuiltInModeID.polish.rawValue))
        XCTAssertEqual(result.polishProvider, .groq, "AI 潤飾 off globally, 潤飾 mode still polishes")
        XCTAssertEqual(result.modeID, BuiltInModeID.polish.rawValue)
        XCTAssertEqual(result.task, .dictation)
        XCTAssertEqual(calls.polishCalls.first?.1.prompt?.id, BuiltInPromptID.standard.rawValue)
        XCTAssertEqual(result.finalText, "我們明天下午三點在公司開會，討論新的專案", "the global punctuation rule still applies")

        // No key at all: told before STT runs.
        let none = PipelineCallLog()
        do {
            _ = try await pipeline(keys: [], transcript: raw, calls: none)
                .run(audioFile: audio, request: DictationRequest(modeID: BuiltInModeID.polish.rawValue))
            XCTFail("expected requiresLLM")
        } catch {
            XCTAssertEqual(error as? PolishError, .requiresLLM(.dictate))
        }
        XCTAssertTrue(none.sttOptions.isEmpty)

        // LLM failure: dictation-type modes fall back to rule-based cleanup.
        let failing = try await pipeline(transcript: raw, calls: PipelineCallLog()) { _, _ in throw ProviderError.http(status: 500, message: "") }
            .run(audioFile: audio, request: DictationRequest(modeID: BuiltInModeID.polish.rawValue))
        XCTAssertEqual(failing.polishProvider, .off)
        XCTAssertEqual(failing.finalText, DictationPipeline.outputStage(RuleBasedCleanup.clean(raw), replacements: { $0 },
                                                                         convertToTraditional: true, spaceBetweenCJKAndLatin: true))
    }

    func testEmailModeUsesTheEmailPrompt() async throws {
        let calls = PipelineCallLog()
        let result = try await pipeline(transcript: "嗯王經理您好我想跟您確認下週的會議時間", calls: calls) { _, _ in
            "王經理您好，我想跟您確認下週的會議時間。"
        }.run(audioFile: audio, request: DictationRequest(fieldHint: .email, modeID: BuiltInModeID.email.rawValue))
        let context = try XCTUnwrap(calls.polishCalls.first?.1)
        XCTAssertEqual(context.prompt?.id, BuiltInPromptID.email.rawValue)
        XCTAssertTrue(PolishPrompt.system(for: context).contains("這段文字會放進 Email 內文"))
        XCTAssertEqual(result.output, .paste)
        XCTAssertEqual(result.finalText, "王經理您好，我想跟您確認下週的會議時間")
    }

    // MARK: 助理

    func testAssistantAnswersAndDoesNotFallBack() async throws {
        let answer = String(repeating: "台北今天多雲，午後可能有雷陣雨，出門記得帶傘。", count: 6)
        let calls = PipelineCallLog()
        let result = try await pipeline(transcript: "今天台北會下雨嗎", calls: calls) { _, _ in answer }
            .run(audioFile: audio, request: DictationRequest(modeID: BuiltInModeID.assistant.rawValue))
        XCTAssertEqual(result.task, .assistant)
        XCTAssertEqual(result.output, .answer)
        XCTAssertEqual(result.finalText, answer, "no punctuation rule on an answer; long output is fine")
        XCTAssertEqual(calls.polishCalls.first?.1.prompt?.kind, .assistant)
        let short = try await pipeline(transcript: "今天台北會下雨嗎", calls: PipelineCallLog()) { _, _ in "會下雨。" }
            .run(audioFile: audio, request: DictationRequest(modeID: BuiltInModeID.assistant.rawValue))
        XCTAssertEqual(short.finalText, "會下雨。", "the short-message punctuation rule is not applied to an answer")

        do {
            _ = try await pipeline(transcript: "今天台北會下雨嗎", calls: PipelineCallLog()) { _, _ in
                throw ProviderError.http(status: 500, message: "")
            }.run(audioFile: audio, request: DictationRequest(modeID: BuiltInModeID.assistant.rawValue))
            XCTFail("an answer must not fall back to inserting the question")
        } catch {
            XCTAssertNotNil(error as? ProviderError)
        }
    }

    // MARK: Overrides reach the pipeline

    func testModeOverridesReachSTTAndTheOutputStage() async throws {
        var mode = DictationModeConfig(name: "英文、不轉繁體")
        mode.recognition = ModeRecognition(engine: .custom(.groqWhisperTurbo), language: .custom("en"))
        mode.textFormat = ModeTextFormat(forceTraditional: .custom(false), punctuationRule: .custom(.keep))
        mode.ai.enabled = .custom(false)
        let calls = PipelineCallLog()
        let log = Log()
        let result = try await pipeline(polish: .groq, modes: DictationModeConfig.builtIns + [mode], transcript: "我们到了。",
                                        calls: calls, log: log)
            .run(audioFile: audio, request: DictationRequest(modeID: mode.id))
        XCTAssertEqual(log.engines, [.groqWhisperTurbo])
        XCTAssertEqual(calls.sttOptions.first?.languageCode, "en")
        XCTAssertEqual(result.sttProvider, .groqWhisperTurbo)
        XCTAssertEqual(result.finalText, "我们到了。", "no Traditional conversion, full stop kept, no LLM")
        XCTAssertTrue(calls.polishCalls.isEmpty)
    }

    func testResolvedConfigurationCanBePassedIn() async throws {
        let calls = PipelineCallLog()
        let log = Log()
        let p = pipeline(transcript: "我們明天見", calls: calls, log: log)
        var resolved = p.resolve(DictationRequest())
        XCTAssertEqual(resolved.modeID, BuiltInModeID.dictate.rawValue)
        resolved.sttProvider = .groqWhisperLarge
        resolved.punctuationRule = .keep
        let result = try await p.run(audioFile: audio, request: DictationRequest(), resolved: resolved)
        XCTAssertEqual(log.engines, [.groqWhisperLarge])
        XCTAssertEqual(result.sttProvider, .groqWhisperLarge)
        let streamed = try await p.run(transcript: "我們明天見。", request: DictationRequest(), resolved: resolved, sttMillis: 5)
        XCTAssertEqual(streamed.finalText, "我們明天見。")
    }

    // MARK: Context (情境感知)

    func testContextIsSentOnlyWhenTheModeAllowsIt() async throws {
        var withClipboard = DictationModeConfig(name: "帶剪貼簿")
        withClipboard.ai.enabled = .custom(true)
        withClipboard.context = ModeContextFlags(clipboard: true, appName: true)
        var without = DictationModeConfig(name: "不帶")
        without.ai.enabled = .custom(true)
        let modes = DictationModeConfig.builtIns + [withClipboard, without]
        let request = { (id: String) in
            DictationRequest(selectedText: "選取的機密", modeID: id, clipboardText: "剪貼簿的機密", appName: "Mail")
        }
        let raw = "嗯幫我把這段話整理一下謝謝"

        let calls = PipelineCallLog()
        _ = try await pipeline(modes: modes, transcript: raw, calls: calls).run(audioFile: audio, request: request(withClipboard.id))
        let allowed = try XCTUnwrap(calls.polishCalls.first?.1)
        XCTAssertEqual(allowed.clipboardText, "剪貼簿的機密")
        XCTAssertEqual(allowed.appName, "Mail")
        XCTAssertNil(allowed.selectedText, "selected text not switched on for this mode")
        XCTAssertTrue(PolishPrompt.userMessage(transcript: raw, context: allowed).contains("<clipboard>\n剪貼簿的機密\n</clipboard>"))

        let none = PipelineCallLog()
        _ = try await pipeline(modes: modes, transcript: raw, calls: none).run(audioFile: audio, request: request(without.id))
        let blocked = try XCTUnwrap(none.polishCalls.first?.1)
        XCTAssertNil(blocked.clipboardText)
        XCTAssertNil(blocked.appName)
        XCTAssertNil(blocked.selectedText)
        for text in [PolishPrompt.system(for: blocked), PolishPrompt.userMessage(transcript: raw, context: blocked)] {
            XCTAssertFalse(text.contains("機密"))
            XCTAssertFalse(text.contains("Mail"))
        }
    }

    // MARK: Diagnostics

    func testDiagnosticsNeverContainContent() async throws {
        let secretName = "秘密模式名稱"
        let secretPrompt = PromptTemplate(id: "user-prompt", name: "秘密提示詞", kind: .dictation, body: "- 秘密提示詞內文。")
        var mode = DictationModeConfig(name: secretName)
        mode.ai = ModeAI(enabled: .custom(true), promptID: secretPrompt.id)
        mode.context = ModeContextFlags(selectedText: true, clipboard: true, appName: true)
        let log = Log()
        let transcript = "秘密的逐字稿內容一共十幾個字"
        let request = DictationRequest(selectedText: "秘密的選取文字", modeID: mode.id, clipboardText: "秘密的剪貼簿",
                                       appName: "秘密App")
        _ = try await pipeline(modes: DictationModeConfig.builtIns + [mode], prompts: PromptLibrary.builtIns + [secretPrompt],
                               transcript: transcript, calls: PipelineCallLog(), log: log) { _, _ in "秘密的輸出" }
            .run(audioFile: audio, request: request)
        let all = log.lines.joined(separator: "\n")
        XCTAssertEqual(log.lines.count, 1)
        XCTAssertTrue(all.contains("mode id=\(mode.id)"), all)
        XCTAssertTrue(all.contains("task=dictation llm=groq prompt=custom*"), all)
        XCTAssertTrue(all.contains("context=selected:7,clipboard:6,app:5"), all)
        XCTAssertFalse(all.contains("秘密"), "no names, prompt text, transcript, selection, clipboard or app name: \(all)")

        let plain = Log()
        _ = try await pipeline(transcript: "我們明天見", calls: PipelineCallLog(), log: plain)
            .run(audioFile: audio, request: DictationRequest(mode: .edit, selectedText: " "))
        XCTAssertEqual(plain.lines, ["mode id=builtin.dictate requested=builtin.rewrite task=dictation llm=off output=paste context=-"])
    }
}
