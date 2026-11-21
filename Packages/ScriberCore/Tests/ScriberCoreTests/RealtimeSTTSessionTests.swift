import XCTest
@testable import ScriberCore
import ScriberShared

/// Scripted socket: records what the session sends and lets the test play the server.
final class FakeRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (RealtimeTransportEvent) -> Void)?
    private var _sent: [String] = []
    private var _closed = false
    private var held: [@Sendable (Error?) -> Void] = []
    private(set) var request: URLRequest?
    /// Withhold send completions (a stalled socket).
    var holdSends = false
    /// Called for every sent message (on the session's queue), e.g. to answer commits.
    var onSend: ((FakeRealtimeTransport, String) -> Void)?

    func open(_ request: URLRequest, onEvent: @escaping @Sendable (RealtimeTransportEvent) -> Void) {
        lock.lock(); self.request = request; handler = onEvent; lock.unlock()
    }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        _sent.append(text)
        let hold = holdSends
        if hold { held.append(completion) }
        lock.unlock()
        if !hold { completion(nil) }
        onSend?(self, text)
    }

    func close() { lock.lock(); _closed = true; lock.unlock() }

    func server(_ json: String) { deliver(.text(json)) }
    func deliver(_ event: RealtimeTransportEvent) {
        lock.lock(); let h = _closed ? nil : handler; lock.unlock()
        h?(event)
    }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    var opened: Bool { lock.lock(); defer { lock.unlock() }; return handler != nil }

    /// Decoded sent messages.
    var messages: [[String: Any]] {
        sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    var audioMessages: [[String: Any]] { messages.filter { $0["commit"] as? Bool == false } }
    var commitMessages: [[String: Any]] { messages.filter { $0["commit"] as? Bool == true } }
    var audioBytes: Int {
        audioMessages.reduce(0) { $0 + (Data(base64Encoded: $1["audio_base_64"] as? String ?? "")?.count ?? 0) }
    }
}

final class RealtimeSTTSessionTests: XCTestCase {
    private func makeSession(_ transport: FakeRealtimeTransport, keyterms: [String] = ["Claude Code"],
                             configure: (inout RealtimeSTTSession.Configuration) -> Void = { _ in }) -> RealtimeSTTSession {
        var configuration = RealtimeSTTSession.Configuration()
        configure(&configuration)
        return RealtimeSTTSession(apiKey: "test-key", parameters: .init(keyterms: keyterms), configuration: configuration,
                                  logTag: "test", endpoint: RealtimeSTTWire.endpoint, makeTransport: { transport })
    }

    /// Loud (speech-like level) or silent 16 kHz PCM16.
    private func audio(seconds: Double, loud: Bool = true) -> Data {
        let count = Int(seconds * 16_000)
        let samples = (0..<count).map { loud ? Float(sin(Double($0) * 0.2) * 0.5) : 0 }
        return PCM16.littleEndianData(from: samples)
    }

    private func eventually(_ timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met in time", file: file, line: line); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Answers every commit with a committed_transcript after a short delay.
    private func answerCommits(_ transport: FakeRealtimeTransport, texts: [String]) {
        let queue = DispatchQueue(label: "fake-server")
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

    // MARK: Happy path

    func testBuffersUntilSessionStartedThenStreamsAndFinishes() async throws {
        let transport = FakeRealtimeTransport()
        answerCommits(transport, texts: ["你好世界。"])
        let session = makeSession(transport)
        session.start()
        session.append(pcm16: audio(seconds: 0.5))
        try await eventually { transport.opened }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(transport.sent.isEmpty, "nothing is sent before session_started")
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "xi-api-key"), "test-key")

        transport.server(RealtimeSTTWireTests.sessionStarted)
        try await eventually { transport.audioMessages.count == 2 }  // 2 × 0.2 s, 0.1 s still pending
        session.append(pcm16: audio(seconds: 0.5))
        transport.server(RealtimeSTTWireTests.partial("你好"))

        let text = try await session.finish()
        XCTAssertEqual(text, "你好世界。")
        XCTAssertEqual(transport.audioBytes, audio(seconds: 1).count, "every byte is sent, the tail before the commit")
        XCTAssertEqual(transport.commitMessages.count, 1)
        XCTAssertEqual(transport.messages.last?["commit"] as? Bool, true)
        for message in transport.audioMessages {
            XCTAssertEqual(message["sample_rate"] as? Int, 16_000)
            XCTAssertEqual(message["message_type"] as? String, "input_audio_chunk")
            XCTAssertNil(message["keyterm_library"], "≤ 50 terms go in the query, not the library")
        }
        XCTAssertTrue(transport.closed)
        let metrics = session.currentMetrics
        XCTAssertNotNil(metrics.connectMillis)
        XCTAssertNotNil(metrics.firstPartialMillis)
        XCTAssertEqual(metrics.commitsSent, 1)
    }

    func testEventsStreamPartialsAndCommits() async throws {
        let transport = FakeRealtimeTransport()
        answerCommits(transport, texts: ["第二段。"])
        let session = makeSession(transport)
        let collector = Task { () -> [RealtimeSTTEvent] in
            var all: [RealtimeSTTEvent] = []
            for await event in session.events { all.append(event) }
            return all
        }
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 0.6))
        transport.server(RealtimeSTTWireTests.partial("第"))
        transport.server(#"{"message_type":"committed_transcript_with_timestamps","text":"第二段。","words":[]}"#)
        transport.server(#"{"message_type":"something_new"}"#)
        _ = try await session.finish()
        let events = await collector.value
        XCTAssertEqual(events.first, .started)
        XCTAssertTrue(events.contains(.partial("第")))
        XCTAssertEqual(events.filter { if case .committed = $0 { return true }; return false }, [.committed("第二段。")],
                       "the timestamps event is ignored, so the text is not duplicated")
    }

    func testFinishWhileStillConnectingFlushesAndCommits() async throws {
        let transport = FakeRealtimeTransport()
        answerCommits(transport, texts: ["很短。"])
        let session = makeSession(transport)
        session.start()
        session.append(pcm16: audio(seconds: 0.7))
        try await eventually { transport.opened }
        let finished = Task { try await session.finish() }
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.server(RealtimeSTTWireTests.sessionStarted)
        let text = try await finished.value
        XCTAssertEqual(text, "很短。")
        XCTAssertEqual(transport.audioBytes, audio(seconds: 0.7).count)
    }

    func testShortTailIsPaddedToTheMinimumCommit() async throws {
        let transport = FakeRealtimeTransport()
        answerCommits(transport, texts: ["嗨。"])
        let session = makeSession(transport)
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 0.1))
        _ = try await session.finish()
        XCTAssertGreaterThanOrEqual(transport.audioBytes, RealtimeSTTWire.minimumCommitBytes,
                                    "a commit with < 0.3 s of audio makes the server close the session")
        XCTAssertEqual(transport.commitMessages.count, 1)
    }

    func testSilentDictationIsNotCommitted() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport)
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 1, loud: false))
        let text = try await session.finish()
        XCTAssertEqual(text, "")
        XCTAssertTrue(transport.commitMessages.isEmpty)
    }

    func testPeriodicCommitsAndAutoCommitsAreAccountedFor() async throws {
        let transport = FakeRealtimeTransport()
        answerCommits(transport, texts: ["一。", "二。", "三。"])
        let session = makeSession(transport) { config in
            config.planner.commitAfter = 0.4
            config.planner.forceAfter = 0.8
        }
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 1.0))   // forced commit at 0.8 s
        try await eventually { transport.commitMessages.count == 1 }
        // The server commits by itself once (as after ~36 s); that must not answer our final commit.
        try await Task.sleep(nanoseconds: 60_000_000)
        transport.server(RealtimeSTTWireTests.committed("自動。"))
        session.append(pcm16: audio(seconds: 0.5))
        let text = try await session.finish()
        XCTAssertEqual(transport.commitMessages.count, 2)
        XCTAssertEqual(text, "一。自動。二。")
        XCTAssertEqual(session.currentMetrics.autoCommits, 1)
    }

    func testKeytermLibraryGoesOnTheFirstChunkOnly() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport, keyterms: (0..<55).map { "term\($0)" })
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 0.6))
        try await eventually { transport.audioMessages.count == 3 }
        XCTAssertEqual(transport.audioMessages[0]["keyterm_library"] as? [String], (50..<55).map { "term\($0)" })
        XCTAssertNil(transport.audioMessages[1]["keyterm_library"])
        let query = URLComponents(url: transport.request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.filter { $0.name == "keyterms" }.count, 50)
        session.cancel()
    }

    // MARK: Failures → finish throws, the caller falls back to batch

    private func finishError(_ session: RealtimeSTTSession) async -> RealtimeSTTError? {
        do {
            _ = try await session.finish()
            return nil
        } catch {
            return error as? RealtimeSTTError
        }
    }

    func testServerErrorFailsTheSession() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport)
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.authError)
        transport.deliver(.closed(code: 1000, reason: ""))
        let error = await finishError(session)
        XCTAssertEqual(error?.reason, .server)
        XCTAssertEqual(error?.serverType, "auth_error")
        XCTAssertEqual(error?.errorDescription, "API key 無效或沒有權限，請到設定檢查")
        XCTAssertTrue(transport.closed)
    }

    func testInvalidRequestDuringHandshake() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport)
        let collector = Task { () -> [RealtimeSTTEvent] in
            var all: [RealtimeSTTEvent] = []
            for await event in session.events { all.append(event) }
            return all
        }
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.tooManyKeyterms)
        let events = await collector.value
        XCTAssertEqual(events, [.error(RealtimeSTTError(.server, serverType: "invalid_request"))])
    }

    func testConnectTimeout() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport) { $0.connectTimeout = 0.15 }
        session.start()
        session.append(pcm16: audio(seconds: 0.3))
        let started = Date()
        let error = await finishError(session)
        XCTAssertEqual(error?.reason, .connectTimeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testFinalCommitTimeout() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport) { $0.commitTimeout = 0.15 }
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 0.6))
        let started = Date()
        let error = await finishError(session)
        XCTAssertEqual(error?.reason, .commitTimeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(transport.closed)
    }

    func testSocketClosedMidwayFails() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport)
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 0.4))
        transport.deliver(.closed(code: 1000, reason: "commit_throttled"))
        let error = await finishError(session)
        XCTAssertEqual(error?.reason, .closed)
        XCTAssertEqual(error?.closeCode, 1000)
    }

    func testHandshakeFailure() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport)
        session.start()
        try await eventually { transport.opened }
        transport.deliver(.failed(code: ProviderError.offlineCode, httpStatus: nil))
        let error = await finishError(session)
        XCTAssertEqual(error?.reason, .handshake)
        XCTAssertEqual(error?.errorDescription, "沒有網路連線，請檢查網路後再試")
    }

    func testStalledSocketFailsInsteadOfBuffering() async throws {
        let transport = FakeRealtimeTransport()
        transport.holdSends = true
        let session = makeSession(transport) { $0.maxSendDelay = 0.1 }
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 0.4))
        try await Task.sleep(nanoseconds: 200_000_000)
        session.append(pcm16: audio(seconds: 0.4))
        let error = await finishError(session)
        XCTAssertEqual(error?.reason, .stalled)
    }

    func testTooMuchAudioWhileConnectingFails() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport) { $0.maxBufferedSeconds = 0.5 }
        session.start()
        session.append(pcm16: audio(seconds: 1))
        let error = await finishError(session)
        XCTAssertEqual(error?.reason, .overflow)
    }

    func testCancelClosesTheSocket() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport)
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 0.4))
        session.cancel()
        let error = await finishError(session)
        XCTAssertEqual(error?.reason, .cancelled)
        XCTAssertTrue(transport.closed)
    }

    func testCancellingTheWaitingTaskCancelsTheSession() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport)
        session.start()
        try await eventually { transport.opened }
        transport.server(RealtimeSTTWireTests.sessionStarted)
        session.append(pcm16: audio(seconds: 0.6))
        let waiting = Task { try await session.finish() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual((error as? RealtimeSTTError)?.reason, .cancelled)
        }
        XCTAssertTrue(transport.closed)
    }

    func testFinishAfterFailureReturnsTheSameError() async throws {
        let transport = FakeRealtimeTransport()
        let session = makeSession(transport)
        session.start()
        try await eventually { transport.opened }
        transport.server(#"{"message_type":"quota_exceeded","error":"x"}"#)
        try await Task.sleep(nanoseconds: 50_000_000)
        session.append(pcm16: audio(seconds: 0.4)) // ignored after failure
        let error = await finishError(session)
        XCTAssertEqual(error?.serverType, "quota_exceeded")
        XCTAssertTrue(transport.sent.isEmpty)
    }
}

/// Tiny lock-protected FIFO for the fake server.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T]
    init(_ items: [T]) { self.items = items }
    func pop() -> T? {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }
}
