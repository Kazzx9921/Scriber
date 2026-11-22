import Foundation
import ScriberShared

// 錄音時暫停媒體 — what is possible on macOS, and what this does (details in docs/PRD-macOS版.md):
//
// - There is no public API to read or control another app's playback. The system's own
//   "now playing" service is the private MediaRemote framework.
// - Since macOS 15.4 the MediaRemote daemon only answers processes whose bundle identifier starts
//   with "com.apple."; loaded inside a third-party app it returns nothing.
// - Simulating the play/pause media key cannot tell whether something is playing and toggles, so it
//   would start music that was not playing. Not used.
// - What is used: Apple's own `/usr/bin/osascript` (identifier com.apple.osascript) runs a short
//   JavaScript for Automation script that loads MediaRemote and reads the now-playing state, and
//   sends the explicit "pause" / "play" commands (never "toggle"). It runs in a separate process,
//   so a MediaRemote change on a future macOS can make it fail but cannot crash Scriber; every
//   failure (missing class, timeout, bad output) turns into `.unavailable` and the setting shows
//   as unavailable.
//
// Safety rules (unit-tested in `MediaPauseTests`):
// - Pause only what is playing ("pause" is sent only when the now-playing app reports playing).
//   The script reads the state again for up to ~1 s to confirm; an unconfirmed pause (browsers
//   can be slow to report) still counts as "sent by Scriber", because the resume step re-checks.
// - Resume only an app Scriber sent "pause" to, only the same app (bundle id and pid), only if it
//   is not playing at that moment (the script checks right before sending "play"), after the
//   chosen delay, and never long after the recording (the Mac slept) or after a system sleep
//   cancelled the recording.
// - A new recording inside the resume delay keeps the media paused instead of pausing again.
// - Nothing waits for any of this: results arrive asynchronously; the pipeline never blocks on it.

/// The now-playing app, as the helper script reports it.
struct NowPlayingState: Codable, Equatable, Sendable {
    var playing: Bool
    var bundle: String
    var pid: Int32
}

struct NowPlayingApp: Equatable, Sendable {
    var bundle: String
    var pid: Int32

    init(bundle: String, pid: Int32) {
        self.bundle = bundle
        self.pid = pid
    }

    init(_ state: NowPlayingState) {
        self.init(bundle: state.bundle, pid: state.pid)
    }

    /// The bundle id is an app identifier, not user content.
    var logDescription: String { "\(bundle.isEmpty ? "unknown-app" : bundle) pid=\(pid)" }
}

enum MediaPauseResult: Equatable, Sendable {
    case notPlaying
    /// Was playing and "pause" was sent. `confirmed`: it reported stopped within the check window
    /// (false: commands may be blocked on this macOS, or the app reports late).
    case paused(NowPlayingApp, confirmed: Bool)
    case unavailable(String)
}

enum MediaResumeResult: Equatable, Sendable {
    case resumed
    /// Not sent: "already-playing", "other-app", …
    case skipped(String)
    /// "play" sent but it did not start.
    case noEffect
    case unavailable(String)
}

/// Whether 錄音時暫停媒體 can be offered on this Mac.
enum MediaAvailability: Equatable, Sendable {
    case unknown
    case available
    /// Reason token for the log; the UI shows one fixed sentence.
    case unavailable(String)
}

/// The helper script's JSON (one line on stdout).
struct MediaScriptReport: Decodable, Equatable, Sendable {
    var ok: Bool
    var error: String?
    var before: NowPlayingState?
    var sent: Bool?
    var after: NowPlayingState?
    var skip: String?

    static func parse(_ output: String) -> MediaScriptReport? {
        let line = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? output
        guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MediaScriptReport.self, from: data)
    }

    var availability: MediaAvailability {
        guard ok, before != nil else { return .unavailable(error ?? "no-state") }
        return .available
    }

    /// Output of the "pause" step.
    var pauseResult: MediaPauseResult {
        guard ok, let before else { return .unavailable(error ?? "no-state") }
        guard before.playing else { return .notPlaying }
        guard let sent else { return .unavailable(error ?? "no-command") }
        guard sent else { return .unavailable("not-sent") }
        return .paused(NowPlayingApp(before), confirmed: after.map { !$0.playing } ?? false)
    }

    /// Output of the "resume" step.
    var resumeResult: MediaResumeResult {
        guard ok else { return .unavailable(error ?? "failed") }
        if let skip { return .skipped(skip) }
        guard sent == true, let after else { return .unavailable(error ?? "no-command") }
        return after.playing ? .resumed : .noEffect
    }
}

/// Talks to the system's now-playing service (`MediaRemoteScript` in the app, a fake in tests).
@MainActor
protocol MediaControlPort: AnyObject {
    /// Read-only: can the state be read on this Mac?
    func probe(_ completion: @escaping @MainActor (MediaAvailability) -> Void)
    /// Pauses the now-playing app if it is playing, and checks that it stopped.
    func pauseIfPlaying(_ completion: @escaping @MainActor (MediaPauseResult) -> Void)
    /// Plays `app` again if it is still the now-playing app and still paused.
    func resume(_ app: NowPlayingApp, _ completion: @escaping @MainActor (MediaResumeResult) -> Void)
    /// The same, without waiting for the result (the app is quitting).
    func resumeDetached(_ app: NowPlayingApp)
}

/// Pause / resume bookkeeping across recordings. Main thread.
@MainActor
final class MediaPauseCoordinator {
    struct Ending: Equatable {
        var at: Date
        var delay: TimeInterval
        var allowResume: Bool
        var reason: String
    }

    enum State: Equatable {
        case idle
        /// The pause request is out; `ended` once the recording is over.
        case pausing(ended: Ending?)
        case pausedByUs(NowPlayingApp, ended: Ending?)
    }

    /// A resume that comes this much later than planned is dropped (the Mac slept in between).
    static let staleGrace: TimeInterval = 10

    private(set) var state: State = .idle
    private let port: MediaControlPort
    private let scheduler: AudioScheduling
    private let log: (String) -> Void
    private var resumeTimer: AudioTimer?

    init(port: MediaControlPort, scheduler: AudioScheduling, log: @escaping (String) -> Void = { DiagLog.log("audio", $0) }) {
        self.port = port
        self.scheduler = scheduler
        self.log = log
    }

    func recordingStarted() {
        switch state {
        case .idle:
            state = .pausing(ended: nil)
            log("media: pause requested")
            port.pauseIfPlaying { [weak self] result in self?.pauseFinished(result) }
        case .pausing:
            state = .pausing(ended: nil)
            log("media: pause still in progress → this recording takes it over")
        case .pausedByUs(let app, _):
            resumeTimer?.cancel()
            resumeTimer = nil
            state = .pausedByUs(app, ended: nil)
            log("media: still paused from the last recording (\(app.logDescription)) → not resuming yet")
        }
    }

    func recordingEnded(delay: TimeInterval, allowResume: Bool, reason: String) {
        let ending = Ending(at: scheduler.now, delay: max(0, delay), allowResume: allowResume, reason: reason)
        switch state {
        case .idle:
            return
        case .pausing:
            state = .pausing(ended: ending)
        case .pausedByUs(let app, _):
            state = .pausedByUs(app, ended: ending)
            scheduleResume(app, ending)
        }
    }

    /// The app is quitting: resume right away what Scriber paused (no delay, no waiting).
    func quitNow() {
        resumeTimer?.cancel()
        resumeTimer = nil
        switch state {
        case .pausedByUs(let app, _):
            log("media: quitting → resume \(app.logDescription) now")
            port.resumeDetached(app)
        case .pausing:
            log("media: quitting while the pause request is out → nothing to resume")
        case .idle:
            break
        }
        state = .idle
    }

    private func pauseFinished(_ result: MediaPauseResult) {
        guard case .pausing(let ending) = state else {
            log("media: pause result after quit ignored \(Self.describe(result))")
            return
        }
        switch result {
        case .paused(let app, let confirmed):
            log("media: paused \(app.logDescription) confirmed=\(confirmed)")
            state = .pausedByUs(app, ended: ending)
            if let ending { scheduleResume(app, ending) }
        case .notPlaying:
            log("media: nothing playing → no pause")
            state = .idle
        case .unavailable(let reason):
            log("media: unavailable (\(reason)) → no pause")
            state = .idle
        }
    }

    private func scheduleResume(_ app: NowPlayingApp, _ ending: Ending) {
        guard ending.allowResume else {
            log("media: not resuming \(app.logDescription) (recording ended by \(ending.reason))")
            state = .idle
            return
        }
        resumeTimer?.cancel()
        log("media: resume \(app.logDescription) in \(Int(ending.delay))s")
        resumeTimer = scheduler.schedule(after: ending.delay) { [weak self] in
            self?.resumeDue(app, ending)
        }
    }

    private func resumeDue(_ app: NowPlayingApp, _ ending: Ending) {
        guard case .pausedByUs(let current, let currentEnding) = state, current == app, currentEnding == ending else { return }
        resumeTimer = nil
        state = .idle
        let late = scheduler.now.timeIntervalSince(ending.at) - ending.delay
        guard late <= Self.staleGrace else {
            log("media: not resuming \(app.logDescription): \(Int(late))s late (Mac slept?)")
            return
        }
        port.resume(app) { [weak self] result in
            self?.log("media: resume \(app.logDescription) → \(Self.describe(result))")
        }
    }

    static func describe(_ result: MediaPauseResult) -> String {
        switch result {
        case .notPlaying: "not-playing"
        case .paused(let app, let confirmed): "paused(\(app.logDescription) confirmed=\(confirmed))"
        case .unavailable(let reason): "unavailable(\(reason))"
        }
    }

    static func describe(_ result: MediaResumeResult) -> String {
        switch result {
        case .resumed: "resumed"
        case .skipped(let why): "skipped(\(why))"
        case .noEffect: "no-effect"
        case .unavailable(let reason): "unavailable(\(reason))"
        }
    }
}
