import XCTest
@testable import ScriberCore
import ScriberShared

/// iOS 「邊講邊辨識」 (`RealtimeDictation` + `DictationPipeline.run(audioFile:request:realtime:backoff:)`):
/// the streamed transcript replaces the upload when it is there; every kind of real-time failure
/// falls back to the recorded file; cancel; back-off; when real time does not apply at all; the
/// per-platform default. Fake socket and fake STT: no network, no microphone.
final class RealtimeDictationTests: XCTestCase {
    private var audioFile: URL!
    private var dictionaryURL: URL!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        audioFile = try makeTempAudioFile()
        dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberRealtimeDictationTests-\(UUID().uuidString).json")
        defaultsSuite = "ScriberRealtimeDictationTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: audioFile.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: dictionaryURL)
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    // MARK: Fixtures

    /// Records every upload (which file, which engine).
    final class UploadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _uploads: [(URL, STTProviderKind)] = []
        private var _lines: [String] = []
        func upload(_ url: URL, _ kind: STTProviderKind) { lock.lock(); _uploads.append((url, kind)); lock.unlock() }
        func line(_ text: String) { lock.lock(); _lines.append(text); lock.unlock() }
        var uploads: [(URL, STTProviderKind)] { lock.lock(); defer { lock.unlock() }; return _uploads }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        var pathLines: [String] { lines.filter { $0.contains("path=") } }
    }

    struct UploadSTT: STTProvider {
        var kind: STTProviderKind
        var transcript: String
        var log: UploadLog
        func transcribe(audioFile: URL, options: STTOptions) async throws -> String {
            log.upload(audioFile, kind)
            return transcript
        }
    }

    struct FailingPolish: PolishProvider {
        func polish(_ transcript: String, context: PolishContext) async throws -> String {
            throw ProviderError.network("polish-down")
        }
    }

    struct EchoPolish: PolishProvider {
        let seen: UploadLog
        func polish(_ transcript: String, context: PolishContext) async throws -> String {
            seen.line("polish-input-chars=\(transcript.count)")
            return "Hello world"
        }
    }

    static let streamedText = "邊講邊辨識的內容"
    static let uploadedText = "上傳辨識的內容"

    private func defaults(stt: STTProviderKind = .elevenLabsScribe, realtime: Bool = true,
                          polish: PolishProviderKind = .off) -> ModeDefaults {
        var d = ModeDefaults(sttProvider: stt, polishProvider: polish, forceTraditional: true,
                             spaceBetweenCJKAndLatin: true, translateTarget: "English")
        d.realtimeEnabled = realtime
        return d
    }

    private func pipeline(_ config: ModeDefaults, modes: [DictationModeConfig] = DictationModeConfig.builtIns,
                          log: UploadLog, polish: (any PolishProvider)? = nil) -> DictationPipeline {
        DictationPipeline(
            config: { config }, modes: { modes }, prompts: { PromptLibrary.builtIns },
            dictionary: DictionaryStore(fileURL: dictionaryURL),
            makeSTT: { kind in UploadSTT(kind: kind, transcript: Self.uploadedText, log: log) },
            makePolish: { kind in kind == .off ? nil : polish },
            log: { log.line($0) })
    }

    private func session(_ transport: FakeRealtimeTransport,
                         configure: (inout RealtimeSTTSession.Configuration) -> Void = { _ in }) -> RealtimeSTTSession {
        var configuration = RealtimeSTTSession.Configuration()
        configure(&configuration)
        return RealtimeSTTSession(apiKey: "test-key", parameters: .init(), configuration: configuration,
                                  logTag: "rt-test", endpoint: RealtimeSTTWire.endpoint, makeTransport: { transport })
    }

    /// Starts a dictation's real-time run on a fake socket.
    private func start(_ resolved: ResolvedModeConfig, transport: FakeRealtimeTransport, backoff: RealtimeBackoff,
                       configure: (inout RealtimeSTTSession.Configuration) -> Void = { _ in }) throws -> RealtimeDictation {
        let made = session(transport, configure: configure)
        switch RealtimeDictation.start(resolved: resolved, backoff: backoff, logTag: "rt-test", makeSession: { _ in .success(made) }) {
        case .success(let run): return run
        case .failure(let skip):
            XCTFail("unexpected skip \(skip)")
            throw skip
        }
    }

    /// Speech-like 16 kHz samples (what the capture tap hands over).
    private func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.2) * 0.5) }
    }

    /// The fake server answers each commit with the next text.
    private func answerCommits(_ transport: FakeRealtimeTransport, with texts: [String]) {
        let queue = DispatchQueue(label: "fake-realtime-server")
        let remaining = Locked(texts)
        transport.onSend = { transport, message in
            guard message.contains(#""commit":true"#) else { return }
            let text = remaining.pop() ?? ""
            queue.asyncAfter(deadline: .now() + 0.02) {
                transport.server(RealtimeSTTWireTests.partial(text))
                transport.server(RealtimeSTTWireTests.committed(text))
            }
        }
    }

    private func eventually(_ timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met in time", file: file, line: line); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    static func isCancelled(_ error: Error) -> Bool {
        if case ProviderError.cancelled? = error as? ProviderError { return true }
        return false
    }

    private func assertContentFree(_ log: UploadLog, file: StaticString = #filePath, line: UInt = #line) {
        for entry in log.lines {
            XCTAssertFalse(entry.contains(Self.streamedText) || entry.contains(Self.uploadedText) || entry.contains("test-key"),
                           "log line carries content: \(entry)", file: file, line: line)
        }
    }

    // MARK: Success: the streamed transcript, no upload

    func testStreamedTranscriptIsUsedAndTheFileIsNotUploaded() async throws {
        let log = UploadLog()
        let backoff = RealtimeBackoff()
        let pipe = pipeline(defaults(), log: log)
        let request = DictationRequest()
        let resolved = pipe.resolve(request)
        XCTAssertNil(RealtimeDictation.skipReason(resolved, backoff: backoff))

        let transport = FakeRealtimeTransport()
        answerCommits(transport, with: [Self.streamedText])
        let run = try start(resolved, transport: transport, backoff: backoff)
        let samples = speech(seconds: 0.5)
        run.append(samples: samples)                       // before session_started: buffered
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        run.append(samples: speech(seconds: 0.5))
        run.stop()                                          // the recording ended

        let result = try await pipe.run(audioFile: audioFile, request: request, realtime: run, backoff: backoff)
        XCTAssertTrue(result.usedRealtime)
        XCTAssertEqual(result.rawTranscript, Self.streamedText)
        XCTAssertFalse(result.finalText.isEmpty)
        XCTAssertTrue(log.uploads.isEmpty, "the recorded file is not uploaded")
        XCTAssertEqual(transport.audioBytes, PCM16.littleEndianData(from: samples).count * 2,
                       "everything recorded was streamed, the buffered start included")
        XCTAssertTrue(transport.closed, "the socket closes once the text is there")
        XCTAssertEqual(log.pathLines.count, 1)
        XCTAssertTrue(log.pathLines[0].contains("path=realtime stopToFinalMs="), log.pathLines[0])
        XCTAssertEqual(backoff.consecutiveFailures, 0)
        assertContentFree(log)
    }

    func testTranslateAtStopStillUsesTheStreamAndOnlyThePostProcessingDiffers() async throws {
        let log = UploadLog()
        let backoff = RealtimeBackoff()
        let pipe = pipeline(defaults(), log: log, polish: EchoPolish(seen: log))
        // An older keyboard chooses translate at the stop; same engine and language.
        let resolved = pipe.resolve(DictationRequest())
        let transport = FakeRealtimeTransport()
        answerCommits(transport, with: [Self.streamedText])
        let run = try start(resolved, transport: transport, backoff: backoff)
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        run.append(samples: speech(seconds: 0.6))
        run.stop()

        let result = try await pipe.run(audioFile: audioFile, request: DictationRequest(mode: .translate),
                                        realtime: run, backoff: backoff)
        XCTAssertTrue(result.usedRealtime)
        XCTAssertEqual(result.task, .translate)
        XCTAssertEqual(result.finalText, "Hello world")
        XCTAssertTrue(log.lines.contains("polish-input-chars=\(Self.streamedText.count)"), "the AI got the streamed text")
        XCTAssertTrue(log.uploads.isEmpty)
    }

    func testAFailureAfterTheStreamIsNotRetriedAsAnUpload() async throws {
        let log = UploadLog()
        let backoff = RealtimeBackoff()
        let pipe = pipeline(defaults(), log: log, polish: FailingPolish())
        let resolved = pipe.resolve(DictationRequest(mode: .translate))
        let transport = FakeRealtimeTransport()
        answerCommits(transport, with: [Self.streamedText])
        let run = try start(resolved, transport: transport, backoff: backoff)
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        run.append(samples: speech(seconds: 0.6))
        run.stop()
        do {
            _ = try await pipe.run(audioFile: audioFile, request: DictationRequest(mode: .translate),
                                   realtime: run, backoff: backoff)
            XCTFail("expected the translate error")
        } catch {
            guard case ProviderError.network("polish-down")? = error as? ProviderError else {
                return XCTFail("expected the translate error, got \(error)")
            }
        }
        XCTAssertTrue(log.uploads.isEmpty, "exactly one path: the transcript was there, the AI failed")
        XCTAssertEqual(backoff.consecutiveFailures, 0, "real time itself worked")
    }

    // MARK: Every real-time failure → the recorded file

    private struct FailureCase {
        var name: String
        var reason: String
        var configure: (inout RealtimeSTTSession.Configuration) -> Void = { _ in }
        var holdSends = false
        var answers: [String]?
        /// Plays the server while "recording".
        var script: (FakeRealtimeTransport, RealtimeDictation, RealtimeDictationTests) async throws -> Void
    }

    private var failures: [FailureCase] {
        [
            FailureCase(name: "no session_started in time", reason: "connect-timeout",
                    configure: { $0.connectTimeout = 0.15 }) { _, run, t in
                run.append(samples: t.speech(seconds: 0.4))
                try await Task.sleep(nanoseconds: 250_000_000)
            },
            FailureCase(name: "offline at connect", reason: "reason=handshake") { transport, run, t in
                try await t.eventually { transport.opened }
                run.append(samples: t.speech(seconds: 0.4))
                transport.deliver(.failed(code: ProviderError.offlineCode, httpStatus: nil))
            },
            FailureCase(name: "key refused", reason: "type=auth_error") { transport, run, t in
                try await t.eventually { transport.opened }
                transport.server(RealtimeSTTWireTests.authError)
                transport.deliver(.closed(code: 1000, reason: ""))
                run.append(samples: t.speech(seconds: 0.4))
            },
            FailureCase(name: "socket closed mid-recording (network change)", reason: "reason=closed") { transport, run, t in
                try await t.eventually { transport.opened }
                transport.server(RealtimeSTTWireTests.sessionStarted)
                run.append(samples: t.speech(seconds: 0.4))
                transport.deliver(.closed(code: 1006, reason: nil))
                run.append(samples: t.speech(seconds: 0.4))
            },
            FailureCase(name: "send failed mid-recording", reason: "reason=transport") { transport, run, t in
                try await t.eventually { transport.opened }
                transport.server(RealtimeSTTWireTests.sessionStarted)
                run.append(samples: t.speech(seconds: 0.4))
                transport.deliver(.failed(code: "connection-lost", httpStatus: nil))
            },
            FailureCase(name: "sends stall", reason: "reason=stalled",
                    configure: { $0.maxSendDelay = 0.1 }, holdSends: true) { transport, run, t in
                try await t.eventually { transport.opened }
                transport.server(RealtimeSTTWireTests.sessionStarted)
                run.append(samples: t.speech(seconds: 0.4))
                try await Task.sleep(nanoseconds: 200_000_000)
                run.append(samples: t.speech(seconds: 0.4))
            },
            FailureCase(name: "too much audio while connecting", reason: "reason=overflow",
                    configure: { $0.maxBufferedSeconds = 0.5 }) { _, run, t in
                run.append(samples: t.speech(seconds: 1))
            },
            FailureCase(name: "final commit never answered", reason: "reason=commit-timeout",
                    configure: { $0.commitTimeout = 0.15 }) { transport, run, t in
                try await t.eventually { transport.opened }
                transport.server(RealtimeSTTWireTests.sessionStarted)
                run.append(samples: t.speech(seconds: 0.6))
            },
            FailureCase(name: "empty transcript", reason: "reason=empty-realtime-transcript", answers: [""]) { transport, run, t in
                try await t.eventually { transport.opened }
                transport.server(RealtimeSTTWireTests.sessionStarted)
                run.append(samples: t.speech(seconds: 0.6))
            },
        ]
    }

    func testEveryRealtimeFailureFallsBackToTheRecordedFile() async throws {
        for failure in failures {
            let log = UploadLog()
            let backoff = RealtimeBackoff()
            let pipe = pipeline(defaults(), log: log)
            let request = DictationRequest()
            let transport = FakeRealtimeTransport()
            transport.holdSends = failure.holdSends
            if let answers = failure.answers { answerCommits(transport, with: answers) }
            let run = try start(pipe.resolve(request), transport: transport, backoff: backoff, configure: failure.configure)
            try await failure.script(transport, run, self)
            run.stop()

            let started = Date()
            let result = try await pipe.run(audioFile: audioFile, request: request, realtime: run, backoff: backoff)
            XCTAssertFalse(result.usedRealtime, failure.name)
            XCTAssertEqual(result.rawTranscript, Self.uploadedText, failure.name)
            XCTAssertEqual(log.uploads.map(\.0), [audioFile], "\(failure.name): the recorded file is uploaded once")
            XCTAssertEqual(log.uploads.map(\.1), [.elevenLabsScribe], failure.name)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2, "\(failure.name): bounded wait")
            XCTAssertEqual(log.pathLines.count, 1, failure.name)
            let line = log.pathLines.first ?? ""
            XCTAssertTrue(line.contains("path=batch") && line.contains(failure.reason), "\(failure.name): \(line)")
            XCTAssertTrue(transport.closed, "\(failure.name): socket closed")
            XCTAssertEqual(backoff.consecutiveFailures, 1, failure.name)
            assertContentFree(log)
        }
    }

    func testAFailureWhileRecordingIsNotedBeforeTheStop() async throws {
        let log = UploadLog()
        let backoff = RealtimeBackoff()
        let pipe = pipeline(defaults(), log: log)
        let transport = FakeRealtimeTransport()
        let run = try start(pipe.resolve(DictationRequest()), transport: transport, backoff: backoff)
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        run.append(samples: speech(seconds: 0.4))
        transport.server(#"{"message_type":"quota_exceeded","error":"x"}"#)
        try await eventually { run.failedWhileRecording != nil }
        run.append(samples: speech(seconds: 0.4))   // recording goes on, nothing more is sent
        run.stop()
        let result = try await pipe.run(audioFile: audioFile, request: DictationRequest(), realtime: run, backoff: backoff)
        XCTAssertFalse(result.usedRealtime)
        XCTAssertEqual(log.uploads.count, 1)
        XCTAssertTrue(log.pathLines.first?.contains("reason=failed-while-recording reason=server type=quota_exceeded") == true,
                      log.pathLines.first ?? "-")
    }

    func testAModeThatNoLongerStreamsAtTheStopUploadsWithoutCountingAFailure() async throws {
        var groq = DictationModeConfig(name: "Groq 模式")
        groq.recognition = ModeRecognition(engine: .custom(.groqWhisperLarge))
        let log = UploadLog()
        let backoff = RealtimeBackoff()
        let pipe = pipeline(defaults(), modes: DictationModeConfig.builtIns + [groq], log: log)
        let transport = FakeRealtimeTransport()
        answerCommits(transport, with: [Self.streamedText])
        let run = try start(pipe.resolve(DictationRequest()), transport: transport, backoff: backoff)
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        run.append(samples: speech(seconds: 0.6))
        run.stop()
        let result = try await pipe.run(audioFile: audioFile, request: DictationRequest(modeID: groq.id),
                                        realtime: run, backoff: backoff)
        XCTAssertFalse(result.usedRealtime)
        XCTAssertEqual(log.uploads.map(\.1), [.groqWhisperLarge], "the mode's own engine")
        XCTAssertTrue(log.pathLines.first?.contains("reason=mode-changed(engine)") == true, log.pathLines.first ?? "-")
        XCTAssertEqual(backoff.consecutiveFailures, 0)
        try await eventually { transport.closed }
    }

    // MARK: Cancel

    func testCancelWhileRecordingClosesTheSocketAndNothingRuns() async throws {
        let log = UploadLog()
        let backoff = RealtimeBackoff()
        let pipe = pipeline(defaults(), log: log)
        let transport = FakeRealtimeTransport()
        let run = try start(pipe.resolve(DictationRequest()), transport: transport, backoff: backoff)
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        run.append(samples: speech(seconds: 0.4))
        run.cancel()
        try await eventually { transport.closed }
        let sentBefore = transport.sent.count
        run.append(samples: speech(seconds: 0.4))
        run.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sent.count, sentBefore, "nothing is sent after cancel")
        do {
            _ = try await pipe.run(audioFile: audioFile, request: DictationRequest(), realtime: run, backoff: backoff)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(Self.isCancelled(error), "\(error)")
        }
        XCTAssertTrue(log.uploads.isEmpty)
        XCTAssertEqual(backoff.consecutiveFailures, 0, "a cancel is not a failure")
    }

    func testCancellingTheJobWhileWaitingForTheFinalTextCancelsTheSession() async throws {
        let log = UploadLog()
        let backoff = RealtimeBackoff()
        let pipe = pipeline(defaults(), log: log)
        let transport = FakeRealtimeTransport()   // never answers the commit (3 s timeout)
        let run = try start(pipe.resolve(DictationRequest()), transport: transport, backoff: backoff)
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        run.append(samples: speech(seconds: 0.6))
        run.stop()
        let audioFile = self.audioFile!
        let job = Task { try await pipe.run(audioFile: audioFile, request: DictationRequest(), realtime: run, backoff: backoff) }
        try await eventually { transport.commitMessages.count == 1 }
        job.cancel()
        let started = Date()
        do {
            _ = try await job.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(Self.isCancelled(error), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "does not wait for the commit timeout")
        XCTAssertTrue(transport.closed)
        XCTAssertTrue(log.uploads.isEmpty, "a cancelled dictation is not uploaded")
        XCTAssertEqual(backoff.consecutiveFailures, 0)
    }

    // MARK: Back-off

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    func testThreeFailuresInARowMeanUploadOnlyForTenMinutes() async throws {
        XCTAssertEqual(RealtimeBackoff.failureLimit, 3)
        XCTAssertEqual(RealtimeBackoff.pause, 600)
        let clock = Clock()
        let backoff = RealtimeBackoff(now: { clock.now })
        let log = UploadLog()
        let pipe = pipeline(defaults(), log: log)
        let resolved = pipe.resolve(DictationRequest())

        for attempt in 1...3 {
            let transport = FakeRealtimeTransport()
            let run = try start(resolved, transport: transport, backoff: backoff)
            try await eventually { transport.opened }
            transport.deliver(.failed(code: ProviderError.offlineCode, httpStatus: nil))
            run.stop()
            let result = try await pipe.run(audioFile: audioFile, request: DictationRequest(), realtime: run, backoff: backoff)
            XCTAssertFalse(result.usedRealtime)
            XCTAssertEqual(backoff.consecutiveFailures, attempt)
            XCTAssertEqual(backoff.pausedSecondsLeft == nil, attempt < 3)
        }
        XCTAssertTrue(log.lines.contains { $0.contains("realtime failed 3× in a row → upload only for 600s") })
        XCTAssertEqual(RealtimeDictation.skipReason(resolved, backoff: backoff), .paused(secondsLeft: 600))

        var asked = false
        let paused = RealtimeDictation.start(resolved: resolved, backoff: backoff, logTag: "t") { _ in
            asked = true
            return .failure(.missingKey)
        }
        XCTAssertEqual(paused.failureValue, .paused(secondsLeft: 600))
        XCTAssertFalse(asked, "no session, no key read, while paused")

        clock.advance(599)
        XCTAssertEqual(backoff.pausedSecondsLeft, 1)
        clock.advance(2)
        XCTAssertNil(RealtimeDictation.skipReason(resolved, backoff: backoff), "tried again after 10 minutes")

        // One success resets the count.
        let transport = FakeRealtimeTransport()
        answerCommits(transport, with: [Self.streamedText])
        let run = try start(resolved, transport: transport, backoff: backoff)
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        run.append(samples: speech(seconds: 0.6))
        run.stop()
        let result = try await pipe.run(audioFile: audioFile, request: DictationRequest(), realtime: run, backoff: backoff)
        XCTAssertTrue(result.usedRealtime)
        XCTAssertEqual(backoff.consecutiveFailures, 0)
        XCTAssertNil(backoff.pausedSecondsLeft)
    }

    func testFailuresThatAreNotInARowDoNotPause() {
        let backoff = RealtimeBackoff()
        XCTAssertFalse(backoff.record(success: false))
        XCTAssertFalse(backoff.record(success: false))
        XCTAssertFalse(backoff.record(success: true))
        XCTAssertFalse(backoff.record(success: false))
        XCTAssertFalse(backoff.record(success: false))
        XCTAssertNil(backoff.pausedSecondsLeft)
        XCTAssertTrue(backoff.record(success: false))
        XCTAssertNotNil(backoff.pausedSecondsLeft)
    }

    // MARK: When real time does not apply → the upload, as before

    func testSettingOffMeansNoSessionAndAnUpload() async throws {
        let log = UploadLog()
        let pipe = pipeline(defaults(realtime: false), log: log)
        let resolved = pipe.resolve(DictationRequest())
        XCTAssertEqual(RealtimeDictation.skipReason(resolved, backoff: RealtimeBackoff()), .unavailable(.disabled))
        var asked = false
        let skipped = RealtimeDictation.start(resolved: resolved, backoff: RealtimeBackoff(), logTag: "t") { _ in
            asked = true
            return .failure(.disabled)
        }
        XCTAssertEqual(skipped.failureValue, .unavailable(.disabled))
        XCTAssertFalse(asked, "no session is made")

        let result = try await pipe.run(audioFile: audioFile, request: DictationRequest(), realtime: nil, backoff: RealtimeBackoff())
        XCTAssertFalse(result.usedRealtime)
        XCTAssertEqual(log.uploads.map(\.0), [audioFile])
        XCTAssertTrue(log.pathLines.isEmpty, "the plain upload logs as before")
    }

    func testOtherEnginesDoNotStream() {
        let backoff = RealtimeBackoff()
        for engine in [STTProviderKind.groqWhisperLarge, .groqWhisperTurbo, .custom] {
            let resolved = ModeResolver.resolve(.builtIn(.dictate), prompts: PromptLibrary.builtIns,
                                                defaults: defaults(stt: engine))
            XCTAssertEqual(RealtimeDictation.skipReason(resolved, backoff: backoff), .unavailable(.engine), engine.rawValue)
        }
        // A mode with its own engine, while the default is Scribe.
        var mode = DictationModeConfig(name: "Groq")
        mode.recognition = ModeRecognition(engine: .custom(.groqWhisperTurbo))
        let resolved = ModeResolver.resolve(mode, prompts: PromptLibrary.builtIns, defaults: defaults())
        XCTAssertEqual(RealtimeDictation.skipReason(resolved, backoff: backoff), .unavailable(.engine))
        // A mode that turns it off for itself.
        var off = DictationModeConfig(name: "不要即時")
        off.recognition = ModeRecognition(realtime: .custom(false))
        XCTAssertEqual(RealtimeDictation.skipReason(ModeResolver.resolve(off, prompts: PromptLibrary.builtIns, defaults: defaults()),
                                                    backoff: backoff), .unavailable(.disabled))
    }

    func testNoElevenLabsKeyMeansNoSession() {
        // The real factory against an empty in-memory keychain: nothing is connected.
        let keychain = FakeKeychain()
        let keys = KeychainStore(service: "com.geekaz.Scriber.tests.realtime", accessGroup: nil,
                                 backend: keychain.backend(groups: ["TEAM.app"]), log: { _ in })
        let resolved = ModeResolver.resolve(.builtIn(.dictate), prompts: PromptLibrary.builtIns, defaults: defaults())
        withExtendedLifetime(keychain) {
            let result = RealtimeDictation.start(resolved: resolved, backoff: RealtimeBackoff(), logTag: "t",
                                                 keys: keys, dictionary: DictionaryStore(fileURL: dictionaryURL))
            XCTAssertEqual(result.failureValue, .unavailable(.missingKey))
        }
    }

    // MARK: Defaults: on for iOS, unchanged (off) for the Mac; stored values win

    func testDefaultIsOnForIOSAndOffForTheMac() throws {
        XCTAssertTrue(AppSettings.realtimeDefault(for: .iOS))
        XCTAssertFalse(AppSettings.realtimeDefault(for: .macOS))
        XCTAssertEqual(SettingsPlatform.current, .macOS, "swift test runs on macOS")

        let empty = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        XCTAssertTrue(AppSettings.realtimeEnabled(in: empty, platform: .iOS), "an iOS install that never saw the switch")
        XCTAssertFalse(AppSettings.realtimeEnabled(in: empty, platform: .macOS), "a Mac that never turned it on")
        XCTAssertFalse(AppSettings.realtimeEnabled(in: empty), "this platform (macOS)")
    }

    func testStoredValuesDecodeAsTheyWere() throws {
        let stored = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        stored.set(false, forKey: "realtimeEnabled")
        XCTAssertFalse(AppSettings.realtimeEnabled(in: stored, platform: .iOS), "turned off on iOS stays off")
        stored.set(true, forKey: "realtimeEnabled")
        XCTAssertTrue(AppSettings.realtimeEnabled(in: stored, platform: .macOS), "a Mac that turned it on keeps it")
        stored.set(0, forKey: "realtimeEnabled")
        XCTAssertFalse(AppSettings.realtimeEnabled(in: stored, platform: .iOS), "a number is read as a Bool")
        stored.set("yes", forKey: "realtimeEnabled")
        XCTAssertTrue(AppSettings.realtimeEnabled(in: stored, platform: .iOS), "an unreadable value means the default")
        XCTAssertFalse(AppSettings.realtimeEnabled(in: stored, platform: .macOS))
    }

    func testStoredModesWithoutTheFieldFollowThePlatformDefault() throws {
        // Modes written before or without 即時 (every iOS file: the iOS editor has no such row).
        let json = """
        [{"id": "builtin.dictate", "name": "聽寫"},
         {"id": "a", "name": "舊", "recognition": {"engine": null, "language": "zh"}},
         {"id": "b", "name": "跟隨", "recognition": {"realtime": null}},
         {"id": "c", "name": "關", "recognition": {"realtime": false}},
         {"id": "d", "name": "Mac 開", "recognition": {"realtime": true}}]
        """
        let modes = try JSONDecoder().decode([DictationModeConfig].self, from: Data(json.utf8))
        var iOS = defaults()
        iOS.realtimeEnabled = AppSettings.realtimeDefault(for: .iOS)
        var mac = defaults()
        mac.realtimeEnabled = AppSettings.realtimeDefault(for: .macOS)
        func realtime(_ id: String, _ d: ModeDefaults) -> Bool {
            ModeResolver.resolve(modes.first { $0.id == id }!, prompts: PromptLibrary.builtIns, defaults: d).realtimeEnabled
        }
        for id in ["builtin.dictate", "a", "b"] {
            XCTAssertTrue(realtime(id, iOS), "\(id) follows the iOS default")
            XCTAssertFalse(realtime(id, mac), "\(id) follows the Mac default")
        }
        XCTAssertFalse(realtime("c", iOS), "a mode that turned it off keeps it off")
        XCTAssertTrue(realtime("d", mac))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
