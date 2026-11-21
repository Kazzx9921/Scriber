import XCTest
@testable import ScriberShared

final class SessionChannelTests: XCTestCase {
    private var directory: URL!
    private var namespace: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionChannelTests-\(UUID().uuidString)", isDirectory: true)
        namespace = "com.geekaz.Scriber.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeChannel() -> SessionChannel {
        SessionChannel(directory: directory, namespace: namespace)
    }

    // MARK: State

    func testStateRoundTrip() {
        let app = makeChannel()
        let keyboard = makeChannel()
        let state = SessionState(heartbeat: Date(), phase: .done, requestID: "r1",
                                 resultText: "你好，世界 hello", errorMessage: nil,
                                 expiresAt: Date().addingTimeInterval(600))
        app.writeState(state)
        XCTAssertEqual(keyboard.readState(), state)
        XCTAssertTrue(keyboard.readState().isAlive())
        XCTAssertFalse(keyboard.readRetryable())
    }

    func testRetryableFlagOnlyCountsForFailedState() {
        let app = makeChannel()
        app.writeState(SessionState(heartbeat: Date(), phase: .failed, requestID: "r1", errorMessage: "網路連線失敗"),
                       retryable: true)
        XCTAssertTrue(makeChannel().readRetryable())

        app.writeState(SessionState(heartbeat: Date(), phase: .done, requestID: "r1", resultText: "ok"), retryable: true)
        XCTAssertFalse(makeChannel().readRetryable())

        // A plain heartbeat write clears it.
        app.writeState(SessionState(heartbeat: Date(), phase: .failed, requestID: "r1", errorMessage: "x"))
        XCTAssertFalse(makeChannel().readRetryable())
    }

    func testMissingOrCorruptStateReadsAsDeadIdle() throws {
        let keyboard = makeChannel()
        XCTAssertEqual(keyboard.readState(), SessionState())
        XCTAssertFalse(keyboard.readState().isAlive())

        try Data("{not json".utf8).write(to: keyboard.stateURL)
        XCTAssertEqual(keyboard.readState(), SessionState())
    }

    func testStateObserverFiresOnChangeButNotOnHeartbeatOnly() {
        let app = makeChannel()
        let keyboard = makeChannel()
        var received: [SessionState] = []
        let first = expectation(description: "first state")
        keyboard.observeState { state in
            XCTAssertTrue(Thread.isMainThread)
            received.append(state)
            if received.count == 1 { first.fulfill() }
        }

        let recording = SessionState(heartbeat: Date(), phase: .recording, requestID: "r1")
        app.writeState(recording)
        wait(for: [first], timeout: 2)

        // Heartbeat-only refreshes must not wake the keyboard.
        for i in 1...3 {
            var beat = recording
            beat.heartbeat = Date().addingTimeInterval(Double(i))
            app.writeState(beat)
        }
        let quiet = expectation(description: "no more callbacks")
        quiet.isInverted = true
        wait(for: [quiet], timeout: 0.4)
        XCTAssertEqual(received.count, 1)

        // A real change does.
        let second = expectation(description: "processing")
        keyboard.observeState { state in
            if state.phase == .processing { second.fulfill() }
        }
        app.writeState(SessionState(heartbeat: Date(), phase: .processing, requestID: "r1"))
        wait(for: [second], timeout: 2)
        XCTAssertEqual(received.last?.phase, .processing)
    }

    // MARK: Commands

    func testCommandsArriveOnceInOrderWithRequests() {
        let app = makeChannel()
        let keyboard = makeChannel()
        var got: [(SessionCommand, DictationRequest?)] = []
        let done = expectation(description: "start + stop")
        app.observeCommands { command, request in
            XCTAssertTrue(Thread.isMainThread)
            got.append((command, request))
            if got.count == 2 { done.fulfill() }
        }

        let request = DictationRequest(id: "r1", mode: .dictate, selectedText: nil, fieldHint: .chat)
        keyboard.send(.start, request: request)
        var translated = request
        translated.mode = .translate
        keyboard.send(.stop, request: translated)
        wait(for: [done], timeout: 2)

        XCTAssertEqual(got.map(\.0), [.start, .stop])
        XCTAssertEqual(got[0].1, request)
        XCTAssertEqual(got[1].1?.mode, .translate)

        // Duplicate notifications for already handled commands do nothing.
        DarwinBridge.post(namespace + ".command")
        DarwinBridge.post(namespace + ".command")
        let quiet = expectation(description: "no duplicates")
        quiet.isInverted = true
        wait(for: [quiet], timeout: 0.4)
        XCTAssertEqual(got.count, 2)
    }

    func testCoalescedNotificationStillDeliversEveryCommand() {
        let app = makeChannel()
        let keyboard = makeChannel()
        var got: [SessionCommand] = []
        app.observeCommands { command, _ in got.append(command) }

        // Three writes, notifications "lost".
        let request = DictationRequest(id: "r2")
        keyboard.send(.start, request: request, sentAt: Date(), post: false)
        keyboard.send(.cancel, request: request, sentAt: Date(), post: false)
        keyboard.send(.start, request: DictationRequest(id: "r3"), sentAt: Date(), post: false)
        app.drainCommands()
        XCTAssertEqual(got, [.start, .cancel, .start])

        app.drainCommands()
        XCTAssertEqual(got.count, 3, "draining again must not replay")
    }

    func testCommandsWrittenBeforeObservingAreIgnored() {
        let keyboard = makeChannel()
        keyboard.send(.start, request: DictationRequest(id: "old"), sentAt: Date(), post: false)

        let app = makeChannel() // e.g. the app process was relaunched
        var got: [SessionCommand] = []
        app.observeCommands { command, _ in got.append(command) }
        app.drainCommands()
        XCTAssertTrue(got.isEmpty)

        keyboard.send(.stop, request: DictationRequest(id: "old"), sentAt: Date(), post: false)
        app.drainCommands()
        XCTAssertEqual(got, [.stop])
    }

    func testStaleStartIsDroppedButStaleStopIsNot() {
        let app = makeChannel()
        let keyboard = makeChannel()
        var got: [SessionCommand] = []
        app.observeCommands { command, _ in got.append(command) }

        let old = Date().addingTimeInterval(-(SessionChannel.startCommandMaxAge + 1))
        keyboard.send(.start, request: DictationRequest(id: "r"), sentAt: old, post: false)
        keyboard.send(.stop, request: DictationRequest(id: "r"), sentAt: old, post: false)
        keyboard.send(.start, request: nil, sentAt: Date(), post: false) // start without request
        app.drainCommands()
        XCTAssertEqual(got, [.stop])
    }

    func testSequenceIsMonotonicAcrossInstancesAndClockStalls() {
        let now = Date()
        let a = makeChannel()
        a.send(.start, request: DictationRequest(id: "1"), sentAt: now, post: false)
        a.send(.stop, request: DictationRequest(id: "1"), sentAt: now, post: false) // same millisecond
        let b = makeChannel() // keyboard torn down and recreated
        b.send(.start, request: DictationRequest(id: "2"), sentAt: now.addingTimeInterval(-10), post: false) // clock went back
        let seqs = a.readCommandLog().records.map(\.seq)
        XCTAssertEqual(seqs.count, 3)
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, 3)
    }

    func testCommandLogIsCapped() {
        let keyboard = makeChannel()
        for i in 0..<(CommandLog.capacity + 5) {
            keyboard.send(.cancel, request: DictationRequest(id: "\(i)"), sentAt: Date(), post: false)
        }
        let log = keyboard.readCommandLog()
        XCTAssertEqual(log.records.count, CommandLog.capacity)
        XCTAssertEqual(log.records.last?.request?.id, "\(CommandLog.capacity + 4)")
    }

    // MARK: Level

    func testLevelRoundTripClampAndStaleness() {
        let app = makeChannel()
        let keyboard = makeChannel()
        XCTAssertEqual(keyboard.readLevel(), 0, "no file yet")

        app.writeLevel(0.42)
        XCTAssertEqual(keyboard.readLevel(), 0.42, accuracy: 0.0001)
        app.writeLevel(3)
        XCTAssertEqual(keyboard.readLevel(), 1)
        app.writeLevel(-1)
        XCTAssertEqual(keyboard.readLevel(), 0)

        let slot = LevelSlot(url: directory.appendingPathComponent("level.bin"))
        let now = LevelSlot.nowMillis()
        slot.write(0.8, stamp: now &- (LevelSlot.staleAfterMillis + 50))
        XCTAssertEqual(slot.read(now: now), 0, "old level reads as silence")
        slot.write(0.8, stamp: now)
        XCTAssertEqual(slot.read(now: now), 0.8, accuracy: 0.0001)
    }

    func testLevelStampSurvivesWrapAround() {
        let slot = LevelSlot(url: directory.appendingPathComponent("wrap.bin"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        slot.write(0.5, stamp: UInt32.max - 10)
        XCTAssertEqual(slot.read(now: 20), 0.5, accuracy: 0.0001) // 31 ms later, across the wrap
    }
}
