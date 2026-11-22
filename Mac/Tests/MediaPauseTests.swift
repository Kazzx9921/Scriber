import XCTest

/// Pause / resume bookkeeping ("only resume what we paused") and the helper script's reports.
/// The real script is only run in its read-only and dry modes.
@MainActor
final class MediaPauseTests: XCTestCase {
    private let music = NowPlayingApp(bundle: "com.apple.Music", pid: 501)

    private func make(_ result: MediaPauseResult = .notPlaying) -> (MediaPauseCoordinator, FakeMediaPort, FakeScheduler) {
        let port = FakeMediaPort()
        port.pauseResult = result
        let scheduler = FakeScheduler()
        return (MediaPauseCoordinator(port: port, scheduler: scheduler, log: { _ in }), port, scheduler)
    }

    func testNothingPlayingIsNeverResumed() {
        let (media, port, scheduler) = make(.notPlaying)
        media.recordingStarted()
        media.recordingEnded(delay: 0, allowResume: true, reason: "finished")
        scheduler.runAllPending()
        XCTAssertTrue(port.resumes.isEmpty)
        XCTAssertEqual(media.state, .idle)
    }

    func testPausedIsResumedAfterTheDelayNotBefore() {
        let (media, port, scheduler) = make(.paused(music, confirmed: true))
        media.recordingStarted()
        XCTAssertEqual(port.pauseRequests, 1)
        scheduler.advance(8) // recording
        media.recordingEnded(delay: 2, allowResume: true, reason: "finished")
        XCTAssertTrue(port.resumes.isEmpty, "the end of the recording never waits for media")
        scheduler.advance(1.9)
        XCTAssertTrue(port.resumes.isEmpty)
        scheduler.advance(0.2)
        XCTAssertEqual(port.resumes, [music])
        XCTAssertEqual(media.state, .idle)
    }

    func testZeroDelayResumesOnTheNextTurn() {
        let (media, port, scheduler) = make(.paused(music, confirmed: true))
        media.recordingStarted()
        media.recordingEnded(delay: 0, allowResume: true, reason: "finished")
        XCTAssertTrue(port.resumes.isEmpty)
        scheduler.advance(0)
        XCTAssertEqual(port.resumes, [music])
    }

    /// An unconfirmed pause (the app reported late) is still resumed; the script's own check
    /// (same app, not playing) keeps that from starting anything that was not paused.
    func testUnconfirmedPauseIsStillResumed() {
        let (media, port, scheduler) = make(.paused(music, confirmed: false))
        media.recordingStarted()
        media.recordingEnded(delay: 1, allowResume: true, reason: "finished")
        scheduler.advance(1)
        XCTAssertEqual(port.resumes, [music])
    }

    func testPauseResultArrivingAfterTheRecordingEnded() {
        let (media, port, scheduler) = make(.paused(music, confirmed: true))
        port.deferPause = true
        media.recordingStarted()
        scheduler.advance(0.3)
        media.recordingEnded(delay: 1, allowResume: true, reason: "finished") // very short recording
        XCTAssertTrue(port.resumes.isEmpty)
        port.completePause()
        scheduler.advance(1)
        XCTAssertEqual(port.resumes, [music])
    }

    func testSleepNeverResumes() {
        let (media, port, scheduler) = make(.paused(music, confirmed: true))
        media.recordingStarted()
        media.recordingEnded(delay: 0, allowResume: false, reason: "sleep")
        scheduler.runAllPending()
        XCTAssertTrue(port.resumes.isEmpty)
        XCTAssertEqual(media.state, .idle)
    }

    func testResumeDueLongAfterTheRecordingIsDropped() {
        let (media, port, scheduler) = make(.paused(music, confirmed: true))
        media.recordingStarted()
        media.recordingEnded(delay: 3, allowResume: true, reason: "finished")
        scheduler.jumpClock(3600) // the lid closed right after; the timer fires on waking
        scheduler.runAllPending()
        XCTAssertTrue(port.resumes.isEmpty, "no music starting after waking the Mac")
    }

    func testNewRecordingInsideTheDelayKeepsItPausedAndResumesOnce() {
        let (media, port, scheduler) = make(.paused(music, confirmed: true))
        media.recordingStarted()
        media.recordingEnded(delay: 3, allowResume: true, reason: "finished")
        scheduler.advance(1)
        media.recordingStarted()
        XCTAssertEqual(port.pauseRequests, 1, "not paused again")
        scheduler.advance(5)
        XCTAssertTrue(port.resumes.isEmpty, "not resumed in the middle of the second recording")
        media.recordingEnded(delay: 3, allowResume: true, reason: "finished")
        scheduler.advance(3)
        XCTAssertEqual(port.resumes, [music])
    }

    func testUnavailableDoesNothing() {
        let (media, port, scheduler) = make(.unavailable("api"))
        media.recordingStarted()
        media.recordingEnded(delay: 0, allowResume: true, reason: "finished")
        scheduler.runAllPending()
        XCTAssertTrue(port.resumes.isEmpty)
        XCTAssertEqual(media.state, .idle)
    }

    func testQuitResumesRightAway() {
        let (media, port, scheduler) = make(.paused(music, confirmed: true))
        media.recordingStarted()
        media.recordingEnded(delay: 5, allowResume: true, reason: "finished")
        media.quitNow()
        XCTAssertEqual(port.detachedResumes, [music])
        scheduler.runAllPending()
        XCTAssertTrue(port.resumes.isEmpty, "the delayed resume is cancelled")
    }

    func testQuitWithNothingPausedDoesNothing() {
        let (media, port, _) = make(.notPlaying)
        media.recordingStarted()
        media.quitNow()
        XCTAssertTrue(port.detachedResumes.isEmpty)
    }

    // MARK: Script reports

    private func report(_ json: String) -> MediaScriptReport {
        MediaScriptReport.parse(json)!
    }

    func testPauseReports() {
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":false,"bundle":"com.apple.Music","pid":501}}"#).pauseResult,
                       .notPlaying)
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":true,"bundle":"com.apple.Music","pid":501},"sent":true,"after":{"playing":false,"bundle":"com.apple.Music","pid":501}}"#).pauseResult,
                       .paused(music, confirmed: true))
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":true,"bundle":"com.apple.Music","pid":501},"sent":true,"after":{"playing":true,"bundle":"com.apple.Music","pid":501}}"#).pauseResult,
                       .paused(music, confirmed: false))
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":true,"bundle":"com.apple.Music","pid":501},"sent":false}"#).pauseResult,
                       .unavailable("not-sent"))
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":true,"bundle":"com.apple.Music","pid":501}}"#).pauseResult,
                       .unavailable("no-command"))
        XCTAssertEqual(report(#"{"ok":false,"error":"api"}"#).pauseResult, .unavailable("api"))
        XCTAssertEqual(report(#"{"ok":false,"error":"api"}"#).availability, .unavailable("api"))
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":false,"bundle":"","pid":0}}"#).availability, .available)
    }

    func testResumeReports() {
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":true,"bundle":"x","pid":1},"skip":"already-playing"}"#).resumeResult,
                       .skipped("already-playing"))
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":false,"bundle":"y","pid":2},"skip":"other-app"}"#).resumeResult,
                       .skipped("other-app"))
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":false,"bundle":"x","pid":1},"sent":true,"after":{"playing":true,"bundle":"x","pid":1}}"#).resumeResult,
                       .resumed)
        XCTAssertEqual(report(#"{"ok":true,"before":{"playing":false,"bundle":"x","pid":1},"sent":true,"after":{"playing":false,"bundle":"x","pid":1}}"#).resumeResult,
                       .noEffect)
        XCTAssertEqual(report(#"{"ok":false,"error":"timeout"}"#).resumeResult, .unavailable("timeout"))
    }

    func testParsingTakesTheLastLineAndRejectsGarbage() {
        XCTAssertNotNil(MediaScriptReport.parse("warning\n{\"ok\":false,\"error\":\"load\"}\n"))
        XCTAssertNil(MediaScriptReport.parse("execution error: Error: nope (-2700)"))
        XCTAssertNil(MediaScriptReport.parse(""))
    }

    /// The real helper script on this Mac, read-only: it compiles, runs and reports in the
    /// expected shape. The dry modes go through the pause/play paths without sending a command.
    func testRealScriptReadOnlyAndDryModes() {
        let (state, stateFailure) = MediaRemoteScript.runBlocking(["state"])
        guard let state else {
            // MediaRemote not loadable here: the feature shows as unavailable. Still a valid outcome.
            return XCTAssertFalse(stateFailure.isEmpty)
        }
        if state.ok {
            XCTAssertNotNil(state.before)
            let (pause, _) = MediaRemoteScript.runBlocking(["pause", "dry"])
            XCTAssertEqual(pause?.ok, true)
            XCTAssertEqual(pause?.sent, false, "dry: nothing sent")
            XCTAssertNotNil(pause?.after)
            let (other, _) = MediaRemoteScript.runBlocking(["play", "no.such.app", "1", "dry"])
            XCTAssertEqual(other?.ok, true)
            if other?.before?.playing == false {
                XCTAssertEqual(other?.skip, "other-app")
            }
            XCTAssertNil(other?.sent)
        } else {
            XCTAssertNotNil(state.error)
        }
    }
}
