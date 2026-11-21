import XCTest
@testable import ScriberShared

/// Channel members the keyboard's state machine relies on: peeking/withdrawing the launch
/// request, and the time a state was published (a result's age).
final class SessionChannelKeyboardTests: XCTestCase {
    private var directory: URL!
    private var namespace: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionChannelKeyboardTests-\(UUID().uuidString)", isDirectory: true)
        namespace = "com.geekaz.Scriber.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeChannel() -> SessionChannel {
        SessionChannel(directory: directory, namespace: namespace)
    }

    func testPeekDoesNotConsumeAndTakeDoes() {
        let keyboard = makeChannel(), app = makeChannel()
        XCTAssertNil(keyboard.peekLaunchRequest())
        let request = DictationRequest(mode: .dictate)
        keyboard.writeLaunchRequest(request)
        XCTAssertEqual(keyboard.peekLaunchRequest()?.id, request.id)
        XCTAssertEqual(keyboard.peekLaunchRequest()?.id, request.id)
        XCTAssertEqual(app.takeLaunchRequest()?.id, request.id)
        XCTAssertNil(keyboard.peekLaunchRequest(), "taken by the app")
    }

    func testWithdrawOnlyRemovesTheNamedRequest() {
        let keyboard = makeChannel(), app = makeChannel()
        let first = DictationRequest(), second = DictationRequest()
        keyboard.writeLaunchRequest(second)
        keyboard.withdrawLaunchRequest(id: first.id) // an older one: nothing happens
        XCTAssertEqual(keyboard.peekLaunchRequest()?.id, second.id)
        keyboard.withdrawLaunchRequest(id: second.id)
        XCTAssertNil(keyboard.peekLaunchRequest())
        XCTAssertNil(app.takeLaunchRequest())
    }

    func testChangedAtMovesOnlyWhenSomethingBesidesTheHeartbeatChanges() throws {
        let app = makeChannel(), keyboard = makeChannel()
        XCTAssertNil(keyboard.readStateChangedAt())
        app.writeState(SessionState(heartbeat: Date(), phase: .recording, requestID: "r1"))
        let recordingAt = try XCTUnwrap(keyboard.readStateChangedAt())
        Thread.sleep(forTimeInterval: 0.02)
        app.writeState(SessionState(heartbeat: Date(), phase: .recording, requestID: "r1")) // heartbeat only
        XCTAssertEqual(keyboard.readStateChangedAt(), recordingAt)
        app.writeState(SessionState(heartbeat: Date(), phase: .done, requestID: "r1", resultText: "好"))
        let doneAt = try XCTUnwrap(keyboard.readStateChangedAt())
        XCTAssertGreaterThan(doneAt, recordingAt)

        // A relaunched app writing the same state keeps the original time.
        let relaunched = makeChannel()
        Thread.sleep(forTimeInterval: 0.02)
        relaunched.writeState(SessionState(heartbeat: .distantPast, phase: .done, requestID: "r1", resultText: "好"))
        XCTAssertEqual(keyboard.readStateChangedAt(), doneAt)
    }

    func testOldStateFilesStillDecode() throws {
        // A state.json written before `changedAt` existed.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"{"state":{"heartbeat":0,"phase":"done","requestID":"r9","resultText":"x"},"retryable":false}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("state.json"))
        let keyboard = makeChannel()
        XCTAssertEqual(keyboard.readState().requestID, "r9")
        XCTAssertNil(keyboard.readStateChangedAt())
    }
}
