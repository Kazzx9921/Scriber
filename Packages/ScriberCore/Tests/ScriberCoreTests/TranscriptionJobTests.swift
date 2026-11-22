import XCTest
@testable import ScriberCore
import ScriberShared

// MARK: - Stubs

/// Thread-safe call log and per-segment behaviour for a fake engine.
final class StubEngine: FileTranscriber, @unchecked Sendable {
    let engine: STTProviderKind = .elevenLabsScribe
    var capabilities: FileTranscriptionCapabilities
    private let lock = NSLock()
    private var _calls: [Int: Int] = [:]
    private var _requests: [FileSTTRequest] = []
    /// (segment index, attempt number starting at 1) → result.
    var behaviour: @Sendable (Int, Int) async throws -> TimedText

    init(capabilities: FileTranscriptionCapabilities = .elevenLabs,
         behaviour: @escaping @Sendable (Int, Int) async throws -> TimedText = { index, _ in StubEngine.words(index) }) {
        self.capabilities = capabilities
        self.behaviour = behaviour
    }

    var calls: [Int: Int] { lock.lock(); defer { lock.unlock() }; return _calls }
    var requests: [FileSTTRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func transcribe(file: URL, request: FileSTTRequest) async throws -> TimedText {
        let index = Int(file.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "") ?? -1
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "segment file must exist while it is transcribed")
        lock.lock()
        _calls[index, default: 0] += 1
        let attempt = _calls[index]!
        _requests.append(request)
        let behaviour = self.behaviour
        lock.unlock()
        return try await behaviour(index, attempt)
    }

    /// "段k。" as one timed word in the middle of the segment.
    static func words(_ index: Int, speaker: String? = nil) -> TimedText {
        TimedText(text: "段\(index)。", granularity: .word,
                  units: [TimedText.Unit(text: "段\(index)。", start: 3, end: 4, speaker: speaker)])
    }
}

final class StubPCMSource: PCMSource, @unchecked Sendable {
    private let audio: SyntheticAudio
    private var position: Int
    init(audio: SyntheticAudio, start: TimeInterval) {
        self.audio = audio
        position = Int(start * 16_000)
    }
    func read() throws -> [Float]? {
        guard position < audio.totalSamples else { return nil }
        defer { position += 4000 }
        return audio.chunk(from: position, count: 4000)
    }
}

@MainActor
final class TranscriptionJobTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberJobTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 45 s, five parts of 9 s, a pause near every planned boundary (9, 18, 27, 36 s).
    static let fiveParts = SyntheticAudio(seconds: 45, silences: [8.6...9.2, 17.9...18.5, 26.5...27.1, 36.2...36.8])

    private func environment(engine: StubEngine, audio: SyntheticAudio = fiveParts, store: TranscriptStore? = nil,
                             makeTranscriber: (@Sendable (STTProviderKind) throws -> any FileTranscriber)? = nil) -> TranscriptionEnvironment {
        var policy = SegmentationPolicy()
        policy.targetSeconds = 10
        policy.searchWindowSeconds = 2
        policy.hardCapSeconds = 20
        policy.overlapSeconds = 1
        let fastRetry = RetryPolicy(maxAttempts: 3, maxRateLimitedAttempts: 4, baseDelay: 0.005, maxDelay: 0.05)
        return TranscriptionEnvironment(
            workRoot: root.appendingPathComponent("work"), store: store ?? TranscriptStore(directory: root.appendingPathComponent("store")),
            policy: policy, retry: fastRetry, concurrency: 3,
            makeTranscriber: makeTranscriber ?? { _ in engine },
            probe: { _ in SourceProbe(duration: audio.seconds) },
            openSource: { _, start in StubPCMSource(audio: audio, start: start) },
            makeWriter: { try WAVSegmentWriter(baseURL: $0) },
            keyterms: { ["Scriber"] },
            postProcessor: { _ in .identity })
    }

    private func sourceFile(_ name: String = "週會錄音.mp3") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("not decoded by the stub source".utf8).write(to: url)
        return url
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func texts(_ store: TranscriptStore, _ job: TranscriptionJob) -> [String] {
        guard let id = job.transcriptID, let record = store.record(id: id) else { return [] }
        return record.paragraphs.map { $0.isMissing ? "<missing>" : $0.text }
    }

    // MARK: Ordering and saving

    /// Later segments finish first; the transcript is still in order and saved once.
    func testOutOfOrderCompletionAssemblesInOrder() async throws {
        let engine = StubEngine { index, _ in
            try await Task.sleep(nanoseconds: UInt64(5 - index) * 40_000_000)
            return StubEngine.words(index)
        }
        let env = environment(engine: engine)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: TranscriptionOptions()).first)
        try await waitFor("done") { job.phase == .done }

        XCTAssertEqual(texts(env.store, job), ["段0。", "段1。", "段2。", "段3。", "段4。"])
        XCTAssertEqual(job.segmentsDone, 5)
        XCTAssertEqual(job.segmentsTotal, 5)
        XCTAssertEqual(job.fraction, 1, accuracy: 0.001)
        XCTAssertEqual(engine.calls, [0: 1, 1: 1, 2: 1, 3: 1, 4: 1])
        XCTAssertEqual(env.store.items.count, 1)
        XCTAssertEqual(env.store.items.first?.title, "週會錄音")
        let record = try XCTUnwrap(env.store.record(id: job.transcriptID!))
        // Absolute times: each word sits 3 s into its segment.
        let starts = record.paragraphs.compactMap(\.start)
        XCTAssertEqual(starts.count, 5)
        XCTAssertEqual(starts[0], 3, accuracy: 0.01)
        XCTAssertTrue(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertFalse(record.cues.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.folder.path), "work files are deleted after success")
        XCTAssertEqual(engine.requests.first?.keyterms, ["Scriber"])
        XCTAssertEqual(engine.requests.first?.languageCode, "zh")
        XCTAssertEqual(engine.requests.first?.diarize, false)
    }

    /// Text appears in order while later segments are still running.
    func testPartialTextIsAvailableAsSegmentsFinish() async throws {
        let engine = StubEngine { index, _ in
            if index > 0 { try await Task.sleep(nanoseconds: 600_000_000) }
            return StubEngine.words(index)
        }
        let queue = TranscriptionQueue(environment: environment(engine: engine), restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("first segment") { job.segmentsDone >= 1 }
        XCTAssertEqual(job.phase, .transcribing)
        XCTAssertEqual(job.paragraphs.map(\.text), ["段0。"])
        XCTAssertGreaterThan(job.fraction, 0)
        XCTAssertLessThan(job.fraction, 1)
        try await waitFor("done") { job.phase == .done }
        XCTAssertEqual(job.paragraphs.count, 5)
    }

    // MARK: Failures and retries

    /// A segment that keeps failing is reported with its time range; the rest is delivered.
    /// Retrying later transcribes only that segment and updates the saved transcript.
    func testFailedSegmentIsReportedAndCanBeRetriedAlone() async throws {
        let healthy = LockedFlag()
        let engine = StubEngine { index, _ in
            if index == 2, !healthy.value { throw ProviderError.http(status: 503, message: "busy") }
            return StubEngine.words(index)
        }
        let env = environment(engine: engine)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("done") { job.phase == .done }

        XCTAssertEqual(job.failedSegments.map(\.index), [2])
        let failed = try XCTUnwrap(job.failedSegments.first)
        XCTAssertEqual(failed.start, 17.9, accuracy: 0.7)
        XCTAssertEqual(failed.end, 27.1, accuracy: 0.7)
        XCTAssertEqual(failed.message, ProviderError.http(status: 503, message: "").errorDescription)
        XCTAssertEqual(engine.calls[2], 3, "three attempts")
        XCTAssertEqual(texts(env.store, job), ["段0。", "段1。", "<missing>", "段3。", "段4。"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.folder.path), "kept for the retry")
        let firstID = job.transcriptID

        healthy.value = true
        queue.retryFailed(job)
        try await waitFor("retried") { job.phase == .done && job.failedSegments.isEmpty }
        XCTAssertEqual(job.transcriptID, firstID, "the same saved transcript is updated")
        XCTAssertEqual(texts(env.store, job), ["段0。", "段1。", "段2。", "段3。", "段4。"])
        XCTAssertEqual(engine.calls, [0: 1, 1: 1, 2: 4, 3: 1, 4: 1], "finished segments are not redone")
        XCTAssertEqual(env.store.items.count, 1)
    }

    /// 429 with Retry-After: waits, retries, and still finishes everything.
    func testRateLimitIsRespected() async throws {
        let engine = StubEngine { index, attempt in
            if attempt == 1, index % 2 == 0 { throw RateLimitedError(retryAfter: 0.05) }
            return StubEngine.words(index)
        }
        let env = environment(engine: engine)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("done") { job.phase == .done }
        XCTAssertTrue(job.failedSegments.isEmpty)
        XCTAssertEqual(engine.calls[0], 2)
        XCTAssertEqual(texts(env.store, job).count, 5)
    }

    func testMissingKeyFailsTheJobWithAClearMessage() async throws {
        let env = environment(engine: StubEngine(), makeTranscriber: { _ in throw ProviderError.missingAPIKey(.elevenLabs) })
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("failed") { if case .failed = job.phase { return true }; return false }
        XCTAssertEqual(job.phase, .failed(ProviderError.missingAPIKey(.elevenLabs).errorDescription!))
        XCTAssertEqual(job.failureKind, .settings)
        XCTAssertTrue(env.store.items.isEmpty)
    }

    /// A bad key mid-way stops the job; segments already done stay done and are not redone on resume.
    func testFatalErrorStopsAndResumeKeepsFinishedSegments() async throws {
        let keyFixed = LockedFlag()
        // The last segment fails only after the others have finished.
        let engine = StubEngine { index, _ in
            if index == 4, !keyFixed.value {
                try await Task.sleep(nanoseconds: 150_000_000)
                throw ProviderError.http(status: 401, message: "invalid_api_key")
            }
            return StubEngine.words(index)
        }
        let env = environment(engine: engine)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("failed") { if case .failed = job.phase { return true }; return false }
        XCTAssertEqual(job.phase, .failed(ProviderError.http(status: 401, message: "").errorDescription!))
        XCTAssertEqual(job.segmentsDone, 4)
        let doneBefore = engine.calls.filter { $0.key < 4 }
        keyFixed.value = true
        queue.resume(job)
        try await waitFor("done") { job.phase == .done }
        XCTAssertEqual(texts(env.store, job), ["段0。", "段1。", "段2。", "段3。", "段4。"])
        for (index, count) in doneBefore {
            XCTAssertEqual(engine.calls[index], count, "segment \(index) was finished before and must not be redone")
        }
    }

    // MARK: Cancel, pause, resume, restore

    func testCancelIsPromptAndCleansUp() async throws {
        let engine = StubEngine { index, _ in
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return StubEngine.words(index)
        }
        let env = environment(engine: engine)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("requests in flight") { !engine.calls.isEmpty }
        let started = Date()
        queue.cancel(job)
        try await waitFor("cancelled", timeout: 3) { job.phase == .cancelled }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.folder.path))
        XCTAssertTrue(env.store.items.isEmpty)
        XCTAssertFalse(queue.isActive)
    }

    /// iOS background expiry: pause keeps finished segments; coming back resumes the rest only.
    func testPauseAndAutoResumeDoNotRedoFinishedSegments() async throws {
        let engine = StubEngine { index, _ in
            try await Task.sleep(nanoseconds: index < 2 ? 1_000_000 : 300_000_000)
            return StubEngine.words(index)
        }
        let env = environment(engine: engine)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("two done") { job.segmentsDone >= 2 }
        queue.pauseAll()
        try await waitFor("paused") { job.phase == .paused }
        XCTAssertTrue(job.autoPaused)
        XCTAssertFalse(queue.isActive)
        let finished = job.segmentsDone
        XCTAssertGreaterThanOrEqual(finished, 2)

        queue.resumeAutoPaused()
        try await waitFor("done") { job.phase == .done }
        XCTAssertEqual(engine.calls[0], 1)
        XCTAssertEqual(engine.calls[1], 1)
        XCTAssertEqual(texts(env.store, job), ["段0。", "段1。", "段2。", "段3。", "段4。"])
    }

    /// Quitting the app mid-way: a new queue on the same folder finds the job paused with its
    /// progress, and finishes it without redoing finished segments.
    func testInterruptedJobIsRestoredAfterRelaunch() async throws {
        let slow = LockedFlag()
        slow.value = true
        let engine = StubEngine { index, _ in
            if index >= 2, slow.value { try await Task.sleep(nanoseconds: 10_000_000_000) }
            return StubEngine.words(index)
        }
        let env = environment(engine: engine)
        var first: TranscriptionQueue? = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(first?.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("two done") { job.segmentsDone >= 2 }
        job.pause(auto: false) // what quitting leaves on disk: an active/paused manifest
        try await waitFor("paused") { job.phase == .paused }
        first = nil

        slow.value = false
        let second = TranscriptionQueue(environment: env)
        let restored = try XCTUnwrap(second.jobs.first)
        XCTAssertEqual(restored.id, job.id)
        XCTAssertEqual(restored.phase, .paused)
        XCTAssertFalse(restored.autoPaused)
        XCTAssertGreaterThanOrEqual(restored.segmentsDone, 2)
        XCTAssertEqual(restored.paragraphs.prefix(2).map(\.text), ["段0。", "段1。"])
        second.resume(restored)
        try await waitFor("done") { restored.phase == .done }
        XCTAssertEqual(engine.calls[0], 1)
        XCTAssertEqual(engine.calls[1], 1)
        XCTAssertEqual(texts(env.store, restored), ["段0。", "段1。", "段2。", "段3。", "段4。"])
    }

    func testFilesQueueUpAndRunOneAtATime() async throws {
        let engine = StubEngine { index, _ in
            try await Task.sleep(nanoseconds: 5_000_000)
            return StubEngine.words(index)
        }
        let env = environment(engine: engine)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let jobs = queue.add([try sourceFile("a.m4a"), try sourceFile("b.mov")], engine: .elevenLabsScribe, options: .init())
        XCTAssertEqual(jobs[1].phase, .waiting)
        try await waitFor("both done") { jobs.allSatisfy { $0.phase == .done } }
        XCTAssertEqual(Set(env.store.items.map(\.title)), ["a", "b"])
        queue.clearFinished()
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    // MARK: Modes

    /// Silence is never uploaded.
    func testSilentSegmentIsSkipped() async throws {
        // Boundaries at 9, 18, 27, 36 s; 8.6–18.5 s is silent, so segment 1 has nothing in it.
        let audio = SyntheticAudio(seconds: 45, silences: [8.6...18.5, 26.5...27.1, 36.2...36.8])
        let engine = StubEngine()
        let env = environment(engine: engine, audio: audio)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("done") { job.phase == .done }
        XCTAssertNil(engine.calls[1])
        XCTAssertEqual(texts(env.store, job), ["段0。", "段2。", "段3。", "段4。"])
    }

    /// Speaker labels: the whole file goes in one request with diarization on.
    func testSpeakerLabelsUseOneRequest() async throws {
        let engine = StubEngine { _, _ in
            TimedText(text: "", granularity: .word, units: [
                .init(text: "你好。", start: 1, end: 2, speaker: "speaker_3"),
                .init(text: "嗨。", start: 4, end: 5, speaker: "speaker_0"),
                .init(text: "再見。", start: 30, end: 31, speaker: "speaker_3"),
            ])
        }
        let env = environment(engine: engine)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe,
                                          options: TranscriptionOptions(timestamps: true, speakers: true)).first)
        try await waitFor("done") { job.phase == .done }
        XCTAssertTrue(job.singleRequest)
        XCTAssertFalse(job.speakersUnavailable)
        XCTAssertEqual(engine.calls, [0: 1])
        XCTAssertEqual(engine.requests.first?.diarize, true)
        XCTAssertEqual(engine.requests.first?.audioSeconds ?? 0, 45, accuracy: 0.01)
        let record = try XCTUnwrap(env.store.record(id: job.transcriptID!))
        XCTAssertTrue(record.hasSpeakers)
        XCTAssertEqual(record.paragraphs.map(\.speaker), [1, 2, 1])
        XCTAssertEqual(TranscriptExport.plainText(record.paragraphs, style: TranscriptExport.style(for: record), duration: record.duration),
                       "[00:01] 說話者 1：你好。\n\n[00:04] 說話者 2：嗨。\n\n[00:30] 說話者 1：再見。")
    }

    func testSpeakerLabelsUnavailableFallsBackToSegments() async throws {
        let engine = StubEngine(capabilities: .groq)
        let env = environment(engine: engine)
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .groqWhisperTurbo,
                                          options: TranscriptionOptions(timestamps: true, speakers: true)).first)
        try await waitFor("done") { job.phase == .done }
        XCTAssertFalse(job.singleRequest)
        XCTAssertTrue(job.speakersUnavailable)
        XCTAssertEqual(engine.calls.count, 5)
        XCTAssertTrue(engine.requests.allSatisfy { !$0.diarize })
    }

    func testEmptyFileFails() async throws {
        let env = environment(engine: StubEngine(), audio: SyntheticAudio(seconds: 0))
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([try sourceFile()], engine: .elevenLabsScribe, options: .init()).first)
        try await waitFor("failed") { if case .failed = job.phase { return true }; return false }
        XCTAssertEqual(job.phase, .failed(TranscriptionError.empty.errorDescription!))
        XCTAssertEqual(job.failureKind, .file, "retrying cannot fix the file itself")
    }

    // MARK: Store

    func testStoreRenameDeleteAndRelaunch() throws {
        let folder = root.appendingPathComponent("store")
        let store = TranscriptStore(directory: folder)
        let record = TranscriptRecord(title: "訪談", duration: 61, engine: .groqWhisperLarge, options: .init(),
                                      granularity: .segment, hasSpeakers: false,
                                      paragraphs: [TranscriptParagraph(start: 0, text: "第一段。")], cues: [], sourceExtension: "mp3")
        XCTAssertTrue(store.save(record))
        store.rename(id: record.id, to: "  訪談（修正）  ")
        let reopened = TranscriptStore(directory: folder)
        XCTAssertEqual(reopened.items.map(\.title), ["訪談（修正）"])
        XCTAssertEqual(reopened.record(id: record.id)?.title, "訪談（修正）")
        XCTAssertEqual(reopened.items.first?.preview, "第一段。")
        // Saving again (retry finished) keeps the user's title.
        XCTAssertTrue(reopened.save(record))
        XCTAssertEqual(reopened.record(id: record.id)?.title, "訪談（修正）")
        reopened.remove(ids: [record.id])
        XCTAssertTrue(TranscriptStore(directory: folder).items.isEmpty)
        XCTAssertNil(reopened.record(id: record.id))
    }
}

/// A Bool shared with `@Sendable` closures.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

// MARK: - Scheduler

final class SegmentSchedulerTests: XCTestCase {
    private func segments(_ count: Int) -> [SegmentInfo] {
        (0..<count).map { SegmentInfo(index: $0, start: Double($0) * 10, end: Double($0 + 1) * 10, fileName: "s\($0)", bytes: 1) }
    }

    private actor Collector {
        var outcomes: [Int: SegmentOutcome] = [:]
        var order: [Int] = []
        var sleeps: [TimeInterval] = []
        func add(_ index: Int, _ outcome: SegmentOutcome) { outcomes[index] = outcome; order.append(index) }
        func slept(_ seconds: TimeInterval) { sleeps.append(seconds) }
    }

    private func fastRetry() -> RetryPolicy { RetryPolicy(maxAttempts: 3, maxRateLimitedAttempts: 4, baseDelay: 0.002, maxDelay: 0.02) }

    func testConcurrencyIsBounded() async {
        let collector = Collector()
        let scheduler = SegmentScheduler(concurrency: 3, retry: fastRetry(), transcribe: { segment in
            try await Task.sleep(nanoseconds: 20_000_000)
            return TimedText(text: "\(segment.index)")
        }, deliver: { await collector.add($0, $1) })
        for segment in segments(10) { await scheduler.enqueue(segment) }
        await scheduler.closeInput()
        let completion = await scheduler.waitUntilDone()
        XCTAssertEqual(completion, .finished)
        let peak = await scheduler.peakRunning
        XCTAssertEqual(peak, 3)
        let count = await collector.outcomes.count
        XCTAssertEqual(count, 10)
    }

    /// 429: honours Retry-After, halves the concurrency, and every segment still succeeds.
    func testRateLimitHalvesConcurrencyAndWaits() async {
        let collector = Collector()
        let attempts = AttemptCounter()
        let scheduler = SegmentScheduler(concurrency: 4, retry: fastRetry(), transcribe: { segment in
            if await attempts.next(segment.index) == 1, segment.index < 2 {
                throw RateLimitedError(retryAfter: 0.03)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
            return TimedText(text: "ok")
        }, deliver: { await collector.add($0, $1) }, sleep: { seconds in
            await collector.slept(seconds)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        })
        for segment in segments(8) { await scheduler.enqueue(segment) }
        await scheduler.closeInput()
        _ = await scheduler.waitUntilDone()
        let outcomes = await collector.outcomes
        XCTAssertEqual(outcomes.count, 8)
        XCTAssertTrue(outcomes.values.allSatisfy { if case .success = $0 { return true }; return false })
        let sleeps = await collector.sleeps
        XCTAssertTrue(sleeps.contains { $0 >= 0.03 }, "waited at least Retry-After: \(sleeps)")
        let limit = await scheduler.limit
        XCTAssertLessThan(limit, 4, "concurrency was lowered after 429")
    }

    func testTransientErrorsAreRetriedThenGiveUp() async {
        let collector = Collector()
        let attempts = AttemptCounter()
        let scheduler = SegmentScheduler(concurrency: 2, retry: fastRetry(), transcribe: { segment in
            let attempt = await attempts.next(segment.index)
            if segment.index == 0, attempt < 3 { throw ProviderError.network(ProviderError.timeoutCode) }
            if segment.index == 1 { throw ProviderError.http(status: 502, message: "") }
            return TimedText(text: "ok")
        }, deliver: { await collector.add($0, $1) })
        for segment in segments(3) { await scheduler.enqueue(segment) }
        await scheduler.closeInput()
        let completion = await scheduler.waitUntilDone()
        XCTAssertEqual(completion, .finished)
        let outcomes = await collector.outcomes
        XCTAssertEqual(outcomes[0], .success(TimedText(text: "ok")))
        XCTAssertEqual(outcomes[1], .failed(ProviderError.http(status: 502, message: "").errorDescription!))
        XCTAssertEqual(outcomes[2], .success(TimedText(text: "ok")))
        let counts = await attempts.counts
        XCTAssertEqual(counts, [0: 3, 1: 3, 2: 1])
    }

    func testRejectedSegmentIsNotRetried() async {
        let collector = Collector()
        let attempts = AttemptCounter()
        let scheduler = SegmentScheduler(concurrency: 1, retry: fastRetry(), transcribe: { segment in
            _ = await attempts.next(segment.index)
            throw ProviderError.http(status: 422, message: "bad audio")
        }, deliver: { await collector.add($0, $1) })
        await scheduler.enqueue(segments(1)[0])
        await scheduler.closeInput()
        _ = await scheduler.waitUntilDone()
        let counts = await attempts.counts
        XCTAssertEqual(counts, [0: 1])
    }

    func testFatalErrorStopsTheRest() async {
        let collector = Collector()
        let scheduler = SegmentScheduler(concurrency: 1, retry: fastRetry(), transcribe: { segment in
            if segment.index == 1 { throw ProviderError.http(status: 401, message: "") }
            return TimedText(text: "ok")
        }, deliver: { await collector.add($0, $1) })
        for segment in segments(5) { await scheduler.enqueue(segment) }
        await scheduler.closeInput()
        let completion = await scheduler.waitUntilDone()
        XCTAssertEqual(completion, .fatal(ProviderError.http(status: 401, message: "").errorDescription!))
        let order = await collector.order
        XCTAssertEqual(order, [0])
    }

    func testCancelStopsInFlightRequestsPromptly() async {
        let collector = Collector()
        let scheduler = SegmentScheduler(concurrency: 3, retry: fastRetry(), transcribe: { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return TimedText(text: "late")
        }, deliver: { await collector.add($0, $1) })
        for segment in segments(6) { await scheduler.enqueue(segment) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        await scheduler.cancel()
        let completion = await scheduler.waitUntilDone()
        XCTAssertEqual(completion, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let count = await collector.outcomes.count
        XCTAssertEqual(count, 0)
    }

    func testErrorClassification() {
        XCTAssertEqual(SegmentFailureKind.classify(ProviderError.missingAPIKey(.groq)),
                       .fatal(ProviderError.missingAPIKey(.groq).errorDescription!))
        XCTAssertEqual(SegmentFailureKind.classify(ProviderError.http(status: 403, message: "")),
                       .fatal(ProviderError.http(status: 403, message: "").errorDescription!))
        XCTAssertEqual(SegmentFailureKind.classify(ProviderError.http(status: 401, message: "quota_exceeded")),
                       .fatal(ProviderError.http(status: 401, message: "quota_exceeded").errorDescription!))
        XCTAssertEqual(SegmentFailureKind.classify(RateLimitedError(retryAfter: 3, message: "quota exceeded")),
                       .fatal(ProviderError.http(status: 402, message: "").errorDescription!))
        XCTAssertEqual(SegmentFailureKind.classify(ProviderError.http(status: 429, message: "too_many_concurrent_requests")),
                       .rateLimited(retryAfter: nil, message: ProviderError.http(status: 429, message: "").errorDescription!))
        XCTAssertEqual(SegmentFailureKind.classify(ProviderError.http(status: 500, message: "")),
                       .transient(ProviderError.http(status: 500, message: "").errorDescription!))
        XCTAssertEqual(SegmentFailureKind.classify(ProviderError.network(ProviderError.offlineCode)),
                       .transient(ProviderError.network(ProviderError.offlineCode).errorDescription!))
        XCTAssertEqual(SegmentFailureKind.classify(ProviderError.http(status: 413, message: "")),
                       .segment(ProviderError.http(status: 413, message: "").errorDescription!))
        XCTAssertEqual(SegmentFailureKind.classify(CancellationError()), .cancelled)
        XCTAssertEqual(SegmentFailureKind.classify(CustomSTTError.missingModel), .fatal(CustomSTTError.missingModel.errorDescription!))
    }
}

actor AttemptCounter {
    var counts: [Int: Int] = [:]
    func next(_ index: Int) -> Int {
        counts[index, default: 0] += 1
        return counts[index]!
    }
}
