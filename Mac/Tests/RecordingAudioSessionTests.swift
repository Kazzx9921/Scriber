import XCTest

/// The order of cues, mute and media around a recording, and that the output is unmuted on every
/// way a recording can end. Everything is fake: no sound, no Core Audio, no media service.
@MainActor
final class RecordingAudioSessionTests: XCTestCase {
    private struct Rig {
        let session: RecordingAudioSession
        let cues: FakeCuePort
        let port: FakeOutputPort
        let media: FakeMediaPort
        let scheduler: FakeScheduler
        let events: EventLog
        let defaults: UserDefaults

        var isMuted: Bool { port.devices[1]?.muted[0] == true }
    }

    private func rig(output: OutputKind = .speaker, playing: Bool = true) -> Rig {
        let events = EventLog()
        let cues = FakeCuePort()
        cues.events = events
        let port = FakeOutputPort()
        port.events = events
        port.addDevice(1, .init(uid: "speakers"), isDefault: true)
        let media = FakeMediaPort()
        media.events = events
        media.pauseResult = playing ? .paused(NowPlayingApp(bundle: "com.spotify.client", pid: 7), confirmed: true) : .notPlaying
        let scheduler = FakeScheduler()
        let defaults = makeTestDefaults(self)
        let muter = OutputMuter(port: port, defaults: defaults, log: { _ in })
        let coordinator = MediaPauseCoordinator(port: media, scheduler: scheduler, log: { _ in })
        let session = RecordingAudioSession(cues: cues, muter: muter, media: coordinator, scheduler: scheduler,
                                            outputKind: { output }, log: { _ in })
        return Rig(session: session, cues: cues, port: port, media: media, scheduler: scheduler, events: events,
                   defaults: defaults)
    }

    private func prefs(mute: Bool = true, pause: Bool = true, delay: Double = 2,
                       start: CueSource = .standard, stop: CueSource = .standard) -> AudioPreferences {
        var prefs = AudioPreferences()
        prefs.muteOutput = mute
        prefs.pauseMedia = pause
        prefs.resumeDelay = delay
        prefs.startCue = CueSetting(source: start)
        prefs.stopCue = CueSetting(source: stop)
        return prefs
    }

    // MARK: Start

    /// Pause → start cue → (microphone) → mute once the cue has played.
    func testStartOrder() {
        let r = rig()
        let plan = r.session.begin(prefs(), tag: "t")
        r.events.add("mic.start") // what the controller does right after `begin`
        XCTAssertEqual(r.events.items, ["media.pause", "cue.start", "mic.start"])
        XCTAssertEqual(plan.cueSeconds, 0.42)
        XCTAssertEqual(plan.muteAfter ?? 0, 0.42 + RecordingAudioSession.muteMargin, accuracy: 0.0001)
        XCTAssertFalse(r.isMuted, "the cue must stay audible")
        r.scheduler.advance(0.49)
        XCTAssertFalse(r.isMuted)
        r.scheduler.advance(0.02)
        XCTAssertTrue(r.isMuted)
        XCTAssertEqual(r.events.items, ["media.pause", "cue.start", "mic.start", "mute"])
    }

    func testWithoutAStartCueTheMuteIsImmediate() {
        let r = rig()
        let plan = r.session.begin(prefs(start: .none), tag: "t")
        XCTAssertEqual(plan.muteAfter, 0)
        XCTAssertNil(plan.cueSeconds)
        XCTAssertTrue(r.isMuted)
        XCTAssertEqual(r.events.items, ["media.pause", "mute"])
    }

    func testLongCustomCueDoesNotDelayTheMuteForever() {
        let r = rig()
        r.cues.durations[.start] = 4.5
        let plan = r.session.begin(prefs(), tag: "t")
        XCTAssertEqual(plan.muteAfter ?? 0, RecordingAudioSession.maxMuteDeferral + RecordingAudioSession.muteMargin,
                       accuracy: 0.0001)
        XCTAssertEqual(plan.silenceGate, RecordingAudioSession.maxSilenceGate)
    }

    func testNothingHappensWhenEverythingIsOff() {
        let r = rig()
        let plan = r.session.begin(prefs(mute: false, pause: false, start: .none, stop: .none), tag: "t")
        r.session.end(.finished)
        r.scheduler.runAllPending()
        XCTAssertEqual(plan, .init(cueSeconds: nil, muteAfter: nil, silenceGate: nil, output: .speaker))
        XCTAssertTrue(r.events.items.isEmpty)
        XCTAssertTrue(r.port.writes.isEmpty)
    }

    // MARK: Silence gate (start cue heard by the microphone)

    func testSilenceGateOnlyWhenTheCuePlaysThroughSpeakers() {
        XCTAssertEqual(rig(output: .speaker).session.begin(prefs(), tag: "t").silenceGate, 0.42)
        XCTAssertNil(rig(output: .headphones).session.begin(prefs(), tag: "t").silenceGate)
        XCTAssertNil(rig(output: .unknown).session.begin(prefs(), tag: "t").silenceGate)
        XCTAssertNil(rig(output: .speaker).session.begin(prefs(start: .none), tag: "t").silenceGate)
    }

    // MARK: End: unmute on every path

    /// Finished: unmute, then the stop cue (so it is audible), then media after the delay.
    func testFinishedOrder() {
        let r = rig()
        _ = r.session.begin(prefs(delay: 2), tag: "t")
        r.scheduler.advance(5)
        r.events.clear()
        r.events.add("mic.stop")
        r.session.end(.finished)
        XCTAssertEqual(r.events.items, ["mic.stop", "unmute", "cue.stop"])
        XCTAssertFalse(r.isMuted)
        r.scheduler.advance(2)
        XCTAssertEqual(r.events.items, ["mic.stop", "unmute", "cue.stop", "media.resume"])
        XCTAssertTrue(r.session.muter.pendingRecords.isEmpty)
    }

    func testCancelIsSilentButStillUnmutesAndResumes() {
        let r = rig()
        _ = r.session.begin(prefs(delay: 1), tag: "t")
        r.scheduler.advance(3)
        r.session.end(.cancelled)
        XCTAssertFalse(r.isMuted)
        XCTAssertEqual(r.cues.played, [.start], "no stop cue on cancel")
        r.scheduler.advance(1)
        XCTAssertEqual(r.media.resumes.count, 1)
    }

    func testMicrophoneFailedToStart() {
        let r = rig()
        _ = r.session.begin(prefs(start: .none), tag: "t") // muted at once
        XCTAssertTrue(r.isMuted)
        r.session.end(.failed)
        XCTAssertFalse(r.isMuted)
        XCTAssertEqual(r.cues.played, [])
        r.scheduler.advance(2)
        XCTAssertEqual(r.media.resumes.count, 1)
    }

    func testSleepUnmutesButDoesNotResumeMedia() {
        let r = rig()
        _ = r.session.begin(prefs(), tag: "t")
        r.scheduler.advance(2)
        XCTAssertTrue(r.isMuted)
        r.session.end(.sleep)
        XCTAssertFalse(r.isMuted)
        r.scheduler.runAllPending()
        XCTAssertTrue(r.media.resumes.isEmpty)
        XCTAssertEqual(r.cues.played, [.start])
    }

    func testQuitWhileRecordingUnmutesAndResumesAtOnce() {
        let r = rig()
        _ = r.session.begin(prefs(delay: 5), tag: "t")
        r.scheduler.advance(2)
        r.session.shutdown()
        XCTAssertFalse(r.isMuted)
        XCTAssertEqual(r.media.detachedResumes.count, 1)
        r.scheduler.runAllPending()
        XCTAssertTrue(r.media.resumes.isEmpty)
    }

    func testQuitInsideTheResumeDelayResumesAtOnce() {
        let r = rig()
        _ = r.session.begin(prefs(delay: 5), tag: "t")
        r.scheduler.advance(2)
        r.session.end(.finished)
        r.scheduler.advance(1)
        r.session.shutdown()
        XCTAssertEqual(r.media.detachedResumes.count, 1)
        r.scheduler.runAllPending()
        XCTAssertTrue(r.media.resumes.isEmpty)
    }

    /// Stopped while the start cue still plays: the mute never happens at all.
    func testStopBeforeTheDeferredMute() {
        let r = rig()
        _ = r.session.begin(prefs(), tag: "t")
        r.scheduler.advance(0.2)
        r.session.end(.finished)
        r.scheduler.runAllPending()
        XCTAssertFalse(r.events.items.contains("mute"))
        XCTAssertTrue(r.port.writes.isEmpty)
    }

    func testEndWithoutBeginDoesNothing() {
        let r = rig()
        r.session.end(.finished)
        XCTAssertTrue(r.events.items.isEmpty)
    }

    /// The muted speaker vanished at the end (Bluetooth speaker switched off): the unmute waits
    /// and happens at the next recording once it is back.
    func testUnmuteOfAVanishedDeviceHappensWhenItReturns() {
        let r = rig()
        _ = r.session.begin(prefs(pause: false, start: .none), tag: "t")
        r.port.devices[1]?.connected = false
        r.session.end(.finished)
        XCTAssertEqual(r.session.muter.pendingRecords.count, 1)
        r.port.devices[1]?.connected = true
        r.port.addDevice(2, .init(uid: "headphones"), isDefault: true)
        _ = r.session.begin(prefs(mute: false, pause: false), tag: "t2")
        XCTAssertEqual(r.port.devices[1]?.muted[0], false)
        XCTAssertTrue(r.session.muter.pendingRecords.isEmpty)
    }

    /// Settings changed mid-recording do not strand anything: the start-time choices finish the job.
    func testEndUsesTheChoicesFromTheStart() {
        let r = rig()
        _ = r.session.begin(prefs(delay: 1), tag: "t")
        r.scheduler.advance(1)
        r.session.end(.finished)
        r.scheduler.advance(1)
        XCTAssertEqual(r.media.resumes.count, 1)
        XCTAssertFalse(r.isMuted)
    }
}
