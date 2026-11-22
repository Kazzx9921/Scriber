import Foundation
import ScriberShared

/// Plays the recording cues (`SoundCues` in the app, a fake in tests).
@MainActor
protocol CuePort: AnyObject {
    /// Plays the cue as `prefs` set it. Returns its length in seconds, nil when nothing plays.
    func play(_ kind: CueKind, prefs: AudioPreferences) -> TimeInterval?
}

/// Everything around one recording that is not the microphone itself: the start and stop cues,
/// muting the output, pausing media. `DictationController` calls `begin` right before the
/// microphone starts and `end` right after it stops (on every path).
///
/// Order at the start (decided in docs/PRD-macOS版.md, 音訊設定):
/// 1. Ask the now-playing app to pause (asynchronous; never waited for).
/// 2. Play the start cue, then the caller starts the microphone at once. The cue is not delayed
///    and capture is not delayed: `NSSound.play()` returns immediately and the engine start
///    overlaps the cue's first note. Nothing captured is ever dropped (that could cut a first
///    syllable said over the cue); instead, when the cue plays through speakers the silence check
///    ignores the first `silenceGate` seconds, so a clip holding only the cue is still
///    "沒有聽到聲音" and is not sent to the speech engine.
/// 3. Mute the output once the cue has finished (capped at `maxMuteDeferral`), or right away when
///    no cue plays.
/// At the end: cancel a mute that has not happened yet → unmute → stop cue (only for a normal
/// stop; cancel stays silent) → resume media after the delay (never blocking anything).
@MainActor
final class RecordingAudioSession {
    struct StartPlan: Equatable {
        /// The start cue's length; nil when none played.
        var cueSeconds: TimeInterval?
        /// When the output gets muted from now; nil when muting is off.
        var muteAfter: TimeInterval?
        /// Seconds at the start of the clip that the silence check ignores.
        var silenceGate: TimeInterval?
        var output: OutputKind
    }

    enum Ending: String {
        /// Normal stop (hotkey, menu, max duration, input lost): stop cue plays.
        case finished
        /// Esc, menu cancel, a hotkey combination: silent.
        case cancelled
        /// The microphone did not start.
        case failed
        /// The Mac is going to sleep: unmute, but do not resume media after waking.
        case sleep
        /// The app is quitting: unmute, resume media right away.
        case quit
    }

    /// Output latency after the cue's last sample before the mute.
    static let muteMargin: TimeInterval = 0.08
    /// A long custom cue does not keep other audio playing for long; the mute cuts it off.
    static let maxMuteDeferral: TimeInterval = 2
    /// The silence check never ignores more than this.
    static let maxSilenceGate: TimeInterval = 1

    private let cues: CuePort
    let muter: OutputMuter
    let media: MediaPauseCoordinator
    private let scheduler: AudioScheduling
    private let outputKind: () -> OutputKind
    private let log: (String) -> Void
    private var active: AudioPreferences?
    private var pendingMute: AudioTimer?

    var isActive: Bool { active != nil }

    init(cues: CuePort, muter: OutputMuter, media: MediaPauseCoordinator, scheduler: AudioScheduling,
         outputKind: @escaping () -> OutputKind, log: @escaping (String) -> Void = { DiagLog.log("audio", $0) }) {
        self.cues = cues
        self.muter = muter
        self.media = media
        self.scheduler = scheduler
        self.outputKind = outputKind
        self.log = log
    }

    /// Right before the microphone starts.
    func begin(_ prefs: AudioPreferences, tag: String) -> StartPlan {
        if active != nil { end(.cancelled) }
        active = prefs
        // An earlier unmute that could not happen (device was away) gets another try.
        if !muter.pendingRecords.isEmpty { muter.restorePending(reason: "before-recording") }
        if prefs.pauseMedia { media.recordingStarted() }
        let output = outputKind()
        let cue = cues.play(.start, prefs: prefs)
        var plan = StartPlan(cueSeconds: cue, muteAfter: nil, silenceGate: nil, output: output)
        if prefs.muteOutput {
            if let cue {
                let delay = min(cue, Self.maxMuteDeferral) + Self.muteMargin
                plan.muteAfter = delay
                pendingMute = scheduler.schedule(after: delay) { [weak self] in self?.applyMute() }
            } else {
                plan.muteAfter = 0
                applyMute()
            }
        }
        if let cue, output == .speaker {
            plan.silenceGate = min(cue, Self.maxSilenceGate)
        }
        log("id=\(tag) begin cue=\(cue.map { String(format: "%.2fs", $0) } ?? "none") output=\(output.rawValue) "
            + "silenceGate=\(plan.silenceGate.map { String(format: "%.2fs", $0) } ?? "none") "
            + "mute=\(plan.muteAfter.map { String(format: "after %.2fs", $0) } ?? "off") pauseMedia=\(prefs.pauseMedia)")
        return plan
    }

    private func applyMute() {
        pendingMute = nil
        guard active != nil else { return }
        _ = muter.muteDefaultOutput()
    }

    /// Right after the microphone stopped (or failed to start). Safe to call when nothing is active.
    func end(_ ending: Ending) {
        guard let prefs = active else { return }
        active = nil
        if let pendingMute {
            pendingMute.cancel()
            self.pendingMute = nil
            log("end=\(ending.rawValue) before the mute happened → mute cancelled")
        }
        muter.restorePending(reason: ending.rawValue)
        if ending == .finished {
            _ = cues.play(.stop, prefs: prefs)
        }
        if ending == .quit {
            media.quitNow()
            return
        }
        guard prefs.pauseMedia else { return }
        media.recordingEnded(delay: prefs.resumeDelay, allowResume: ending != .sleep, reason: ending.rawValue)
    }

    /// The app is quitting while idle: undo anything still pending.
    func shutdown() {
        if active != nil {
            end(.quit)
        } else {
            muter.restorePending(reason: "quit")
            media.quitNow()
        }
    }
}
