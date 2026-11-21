import Foundation
import Observation
import UIKit
import os
import ScriberCore
import ScriberShared

// CONTRACT FILE — implementation owned by the "audio + session + keyboard" agent.
// The app UI (other agent) only uses the public surface below.

/// Owns the microphone, the background listening session, and runs the pipeline.
/// Serves two callers: the keyboard (through SessionChannel) and the in-app test area (direct calls).
///
/// ## Sessions and standby
/// A session is "the keyboard can reach this process": the heartbeat in the shared state is
/// fresh, so the keyboard sends `.start` over the Darwin channel instead of opening the app.
/// Opening the app (scriber://session) always starts one, in the foreground, with a live input.
/// What happens after a keyboard dictation depends on `AppSettings.standbyMode`:
///   - `.off`: one-shot. The session ends when the request is finished; every dictation opens
///     the app. (After a retryable failure it stays a minute so "retry" can reach it.)
///   - `.mutedInput`: the input engine keeps running with the app's input muted
///     (`AVAudioApplication.setInputMuted`). A start only unmutes. Reported (Dictus E1, one iPhone,
///     10/10 background starts, 47–113 ms to first sample) to hide the orange indicator;
///     unverified here.
///   - `.outputOnly`: the input engine is stopped; a silent mixable output engine keeps the
///     process running. A start has to start the microphone from the background, which iOS may
///     refuse. A refusal ends the session (the keyboard then opens the app) and is remembered,
///     so `.outputOnly` behaves like `.off` until the user retries it in Settings.
/// Standby ends after `standbyMinutes` without a dictation, on audio that cannot be revived, or
/// when the mode is turned off. Every step is written to `DiagLog`.
@MainActor
@Observable
final class DictationEngine {
    static let shared = DictationEngine()

    enum MicPermission { case undetermined, denied, granted }

    /// What the audio hardware is doing for the session.
    enum Posture: String {
        /// Nothing running, session inactive.
        case released
        /// Input engine running, unmuted: recording, or a one-shot session waiting for it.
        case live
        /// Input engine running with the app's input muted (`.mutedInput` standby, idle).
        case muted
        /// Input stopped, silent output running (`.outputOnly` standby, idle).
        case keepAlive
    }

    enum AutoReturnStatus: Equatable {
        case idle
        case returning(appName: String)
        case failed(appName: String)
    }

    // MARK: Observable state for the UI
    private(set) var micPermission: MicPermission = .undetermined
    /// True while the background listening session is alive (keyboard can record without opening the app).
    private(set) var isSessionActive = false
    private(set) var sessionExpiresAt: Date?
    private(set) var phase: SessionPhase = .idle
    /// 0...1 input level while recording.
    private(set) var level: Float = 0
    private(set) var lastResult: PipelineResult?
    private(set) var lastErrorMessage: String?
    /// The last failure kept its audio (network/server error); `retryLastFailed()` re-runs it.
    private(set) var canRetry = false
    private(set) var posture: Posture = .released
    private(set) var autoReturnStatus: AutoReturnStatus = .idle
    /// Set when iOS refused a background microphone start in `.outputOnly` (see `StandbyMemory`).
    private(set) var outputOnlyRefusal: StandbyMemory.Refusal?

    /// The standby that actually applies: `.outputOnly` falls back to `.off` after a refusal.
    var effectiveStandbyMode: StandbyMode {
        let mode = AppSettings.shared.standbyMode
        if mode == .outputOnly, outputOnlyRefusal != nil { return .off }
        return mode
    }

    // MARK: Tuning
    static let minimumSpeechSeconds: TimeInterval = 0.3
    /// Peak metered level below this (≈ -44 dBFS RMS) counts as silence and is not uploaded.
    static let silenceLevel: Float = 0.12
    static let maximumRecordingSeconds: TimeInterval = 900
    /// A `.done` result is cleared from the shared state after this, so dictated text does not
    /// sit in the App Group. Matches the keyboard's insertion window.
    static let resultRetention: TimeInterval = 120
    /// How long an audio interruption (call, Siri, another recording app) may last before the
    /// session gives up and lets the keyboard re-open the app.
    static let interruptionGrace: TimeInterval = 60
    /// One-shot (`.off`) safety net: an opened session with no recording gives the mic back after this.
    static let idleSessionSeconds: TimeInterval = 60
    /// One-shot: after a retryable failure the session stays this long so "retry" can reach it.
    static let retryWindowSeconds: TimeInterval = 60
    /// A `.start` with a new id while the capture started for the launch request is younger
    /// than this continues that capture instead of discarding it (see `keyboardStart`).
    static let launchAdoptWindow: TimeInterval = 90
    /// Shown on the keyboard when this process cannot start the microphone from the background.
    /// The session is ended with it, so the keyboard's next tap opens the app.
    static let needsAppMessage = "這次要打開 Scriber 才能錄音，請再點一下麥克風"

    // MARK: Private state
    private enum Origin: String { case keyboard, app }
    private struct Capture {
        let token = UUID()
        var request: DictationRequest
        var origin: Origin
        var url: URL
        var startedAt: Date
        /// Started for the request the keyboard left in the launch file when it opened the app.
        var fromLaunch: Bool
        /// When the start command (or the URL that carried it) reached this process.
        var receivedAt: Date
    }
    private struct Job {
        var request: DictationRequest
        var origin: Origin
        var url: URL
        var task: Task<Void, Never>
    }
    private struct LaunchContext {
        var at: Date
        /// False when the keyboard was used inside Scriber itself: nothing to return to.
        var fromOtherApp: Bool
    }

    @ObservationIgnored private let log = Logger(subsystem: "com.geekaz.Scriber", category: "engine")
    @ObservationIgnored private let channel = SessionChannel()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let files = RecordingFiles()
    @ObservationIgnored private var heartbeatTimer: Timer?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var shared = SessionState()
    @ObservationIgnored private var sharedRetryable = false
    @ObservationIgnored private var sharedPhaseSince = Date()
    @ObservationIgnored private var capture: Capture?
    @ObservationIgnored private var job: Job?
    @ObservationIgnored private var kept: (url: URL, request: DictationRequest, origin: Origin)?
    @ObservationIgnored private var pendingSessionStart = false
    /// The session should end as soon as the running capture/job is finished.
    @ObservationIgnored private var pendingSessionEnd: String?
    @ObservationIgnored private var interruptedSince: Date?
    @ObservationIgnored private var lastResumeProbe = Date.distantPast
    @ObservationIgnored private var lastActivityAt: Date?
    @ObservationIgnored private var launchContext: LaunchContext?
    @ObservationIgnored private var maxDurationWork: DispatchWorkItem?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Spoken length of the last clip sent to the pipeline (also the one kept for retry), for `UsageStats`.
    @ObservationIgnored private var lastClipSeconds: Double = 0

    private init() {
        files.purge()
        refreshMicPermission()
        // The first AAC encoder setup is slow; get it out of the way before the first clip.
        Task.detached(priority: .utility) {
            let millis = CaptureBuffer.prewarmEncoder()
            DiagLog.log("rec", "encoder prewarm ms=\(millis)")
        }
        outputOnlyRefusal = StandbyMemory.outputOnlyRefusal

        shared = channel.readState()
        let settings = AppSettings.shared
        DiagLog.log("engine", "process start app=\(EngineDiag.appVersion) iOS=\(UIDevice.current.systemVersion) "
                    + "device=\(EngineDiag.deviceModel) standby=\(settings.standbyMode.rawValue)/\(settings.standbyMinutes)m "
                    + "effective=\(effectiveStandbyMode.rawValue) keepAliveCat=\(StandbyMemory.keepAliveCategory.rawValue) "
                    + "refused=\(outputOnlyRefusal != nil) autoReturn=\(settings.autoReturn) "
                    + "target=\(AutoReturnCatalog.selectedID ?? "none") kbCapture=\(settings.inKeyboardCapture) "
                    + "disk=\(shared.phase.rawValue)/\(EngineDiag.id(shared.requestID)) app=\(EngineDiag.appState)")

        // A previous process that died mid-request left an orphaned phase behind.
        if shared.phase == .recording || shared.phase == .processing {
            DiagLog.log("engine", "orphaned \(shared.phase.rawValue) id=\(EngineDiag.id(shared.requestID)) from the previous process → failed")
            shared.phase = .failed
            shared.errorMessage = "Scriber 剛才被系統關閉，請再說一次"
            shared.resultText = nil
            writeShared()
        }

        let channel = self.channel
        recorder.capture.onLevel = { [weak self] value in
            channel.writeLevel(value)
            Task { @MainActor in self?.level = value }
        }
        recorder.onEvent = { [weak self] event in self?.handle(event) }
        channel.observeCommands { [weak self] command, request in
            self?.handle(command, request: request)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logLifecycle("didEnterBackground") }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logLifecycle("willEnterForeground") }
        })

        #if DEBUG
        // `xcrun simctl launch <udid> com.geekaz.Scriber -ScriberAutoSession YES` starts the
        // session without the URL confirmation dialog `simctl openurl` shows.
        if UserDefaults.standard.bool(forKey: "ScriberAutoSession") {
            DispatchQueue.main.async { [weak self] in self?.startSession() }
        }
        #endif
    }

    func refreshMicPermission() {
        switch AudioRecorder.permission {
        case .granted: micPermission = .granted
        case .denied: micPermission = .denied
        default: micPermission = .undetermined
        }
        // For the keyboard's in-keyboard capture (same key/values as MicPermissionMirror.m).
        let mirrored: String
        switch micPermission {
        case .granted: mirrored = "granted"
        case .denied: mirrored = "denied"
        case .undetermined: mirrored = "undetermined"
        }
        SessionChannel.publishAppMicrophonePermission(mirrored)
    }

    func requestMicPermission() async -> Bool {
        let granted = await AudioRecorder.requestPermission()
        refreshMicPermission()
        DiagLog.log("engine", "mic permission requested granted=\(granted)")
        return granted
    }

    // MARK: Session

    /// Starts (or extends) the background listening session. Called when the app is opened
    /// via scriber://session and from the listening screen's retry button.
    func startSession() {
        DiagLog.log("engine", "startSession app=\(EngineDiag.appState) session=\(isSessionActive) posture=\(posture.rawValue) pendingStart=\(pendingSessionStart)")
        guard ensurePermission(then: { [weak self] in self?.startSession() }) else {
            DiagLog.log("engine", "startSession waits for microphone permission (\(micPermission))")
            return
        }
        // iOS only lets the microphone start while the app is in front. Opened from the
        // keyboard, the scene may still be `.inactive` for a moment: start on didBecomeActive.
        guard UIApplication.shared.applicationState == .active else {
            pendingSessionStart = true
            DiagLog.log("engine", "startSession deferred until active (app=\(EngineDiag.appState))")
            return
        }
        pendingSessionStart = false
        do {
            try makeInputLive(context: "startSession")
        } catch {
            lastErrorMessage = error.localizedDescription
            DiagLog.log("engine", "startSession failed: microphone did not start in the foreground")
            // Tell the keyboard instead of leaving the request it launched us with hanging.
            if let request = channel.takeLaunchRequest() {
                fail(request, origin: .keyboard, message: "無法啟動麥克風，可能正被通話或其他 App 使用",
                     retryable: false, deleteURL: nil)
            }
            launchContext = nil
            if isSessionActive { endSession(reason: "micStartFailed") } else { releaseAudio(context: "micStartFailed") }
            return
        }
        interruptedSince = nil
        lastErrorMessage = nil
        let wasActive = isSessionActive
        isSessionActive = true
        pendingSessionEnd = nil
        clearStaleResult()
        extendSession()
        startHeartbeat()
        DiagLog.log("engine", "session \(wasActive ? "resumed" : "started") standby=\(effectiveStandbyMode.rawValue) "
                    + "minutes=\(AppSettings.shared.standbyMinutes) expiresIn=\(expiresInText)")
        // Opened by the keyboard's mic: start recording right away, no second tap needed.
        if let request = channel.takeLaunchRequest() {
            DiagLog.log("engine", "launch request id=\(EngineDiag.id(request.id)) mode=\(request.mode.rawValue) "
                        + "field=\(request.fieldHint.rawValue) sel=\(request.selectedText != nil)")
            keyboardStart(request, fromLaunch: true, receivedAt: launchContext?.at ?? Date())
        } else {
            DiagLog.log("engine", "no launch request (none, or older than 20 s)")
            launchContext = nil
            enterStandbyIdle(context: "noLaunchRequest")
        }
    }

    func endSession() {
        endSession(reason: "requested")
    }

    private func endSession(reason: String) {
        pendingSessionStart = false
        pendingSessionEnd = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        interruptedSince = nil
        let wasActive = isSessionActive
        isSessionActive = false
        sessionExpiresAt = nil
        if let capture, capture.origin == .keyboard {
            let timing = recorder.discardClip()
            DiagLog.log("engine", "capture discarded id=\(EngineDiag.id(capture.request.id)) reason=sessionEnd \(timing?.summary ?? "")")
            self.capture = nil
            maxDurationWork?.cancel()
            phase = .idle
            level = 0
            channel.writeLevel(0)
            fail(capture.request, origin: .keyboard, message: "Scriber 已停止錄音，請重新啟動", retryable: false, deleteURL: nil)
        }
        if capture == nil { releaseAudio(context: "end:\(reason)") }
        // Heartbeat goes to distantPast: the keyboard must re-open the app from now on.
        writeShared()
        if wasActive { DiagLog.log("engine", "session ended reason=\(reason) → keyboard opens the app on the next tap") }
    }

    /// Ends the session now if nothing is in flight, otherwise right after it.
    private func endSessionWhenIdle(reason: String) {
        if capture == nil, job == nil {
            endSession(reason: reason)
        } else if pendingSessionEnd == nil {
            pendingSessionEnd = reason
            DiagLog.log("engine", "session will end after the current request reason=\(reason)")
        }
    }

    /// Handle scriber:// URLs. Returns true if handled.
    /// `openedFromOtherApp` is false when the keyboard was used inside Scriber itself.
    @discardableResult
    func handle(url: URL, openedFromOtherApp: Bool = true) -> Bool {
        guard url.scheme?.lowercased() == AppGroup.urlScheme else { return false }
        switch url.host?.lowercased() {
        case "session":
            DiagLog.log("app", "url session app=\(EngineDiag.appState) fromOtherApp=\(openedFromOtherApp) "
                        + "session=\(isSessionActive) posture=\(posture.rawValue) pendingStart=\(pendingSessionStart) "
                        + "capture=\(capture != nil) job=\(job != nil)")
            launchContext = LaunchContext(at: Date(), fromOtherApp: openedFromOtherApp)
            autoReturnStatus = .idle
            startSession()
            return true
        default:
            DiagLog.log("app", "url not handled host=\(url.host ?? "-")")
            return false
        }
    }

    /// Settings changed the standby mode or duration.
    func standbySettingsChanged() {
        outputOnlyRefusal = StandbyMemory.outputOnlyRefusal
        let mode = effectiveStandbyMode
        DiagLog.log("engine", "settings standby=\(AppSettings.shared.standbyMode.rawValue)/\(AppSettings.shared.standbyMinutes)m "
                    + "effective=\(mode.rawValue) session=\(isSessionActive) posture=\(posture.rawValue)")
        guard isSessionActive else { return }
        if mode == .off {
            endSessionWhenIdle(reason: "standbyTurnedOff")
            return
        }
        if capture == nil, job == nil { enterStandbyIdle(context: "settingsChanged") }
        if isSessionActive { extendSession() }
    }

    /// Settings → "再試一次" after a refused `.outputOnly` start.
    func retryOutputOnly() {
        StandbyMemory.outputOnlyRefusal = nil
        DiagLog.log("engine", "outputOnly refusal cleared by the user")
        standbySettingsChanged()
    }

    // MARK: In-app test area (works without a session)

    func startRecording(request: DictationRequest = DictationRequest()) {
        guard capture == nil else { return }
        guard ensurePermission(then: { [weak self] in self?.startRecording(request: request) }) else { return }
        cancelJob()
        lastErrorMessage = nil
        DiagLog.log("engine", "in-app start id=\(EngineDiag.id(request.id)) session=\(isSessionActive) posture=\(posture.rawValue)")
        do {
            try makeInputLive(context: "inApp")
            try beginCapture(request, origin: .app)
        } catch {
            lastErrorMessage = error.localizedDescription
            phase = .failed
            DiagLog.log("engine", "in-app start failed \(EngineDiag.error((error as? AudioRecorder.Failure)?.underlying ?? error))")
            settleAudioAfterCapture(context: "inAppStartFailed")
        }
    }

    /// Stops recording and runs the pipeline; result lands in `lastResult` / `lastErrorMessage` and HistoryStore.
    func stopRecordingAndTranscribe() {
        guard let capture else { return }
        finishCapture(capture.request)
    }

    func cancelRecording() {
        if let capture {
            discardCapture(reason: "cancel")
            if capture.origin == .keyboard { publish(.idle, requestID: capture.request.id) }
            phase = .idle
            settleAudioAfterCapture(context: "cancel")
        } else if let job {
            let origin = job.origin, id = job.request.id
            cancelJob()
            phase = .idle
            if origin == .keyboard { publish(.idle, requestID: id) }
        }
    }

    /// Re-runs the pipeline on the audio kept after a network/server failure.
    func retryLastFailed() {
        guard let kept, job == nil, capture == nil else { return }
        runPipeline(url: kept.url, request: kept.request, origin: kept.origin)
    }

    // MARK: Keyboard commands

    private func handle(_ command: SessionCommand, request: DictationRequest?) {
        let receivedAt = Date()
        log.info("command \(command.rawValue, privacy: .public) \(request?.id ?? "-", privacy: .public)")
        DiagLog.log("engine", "cmd \(command.rawValue) id=\(EngineDiag.id(request?.id)) mode=\(request?.mode.rawValue ?? "-") "
                    + "app=\(EngineDiag.appState) session=\(isSessionActive) posture=\(posture.rawValue) "
                    + "idleFor=\(lastActivityAt.map { "\(Int(receivedAt.timeIntervalSince($0)))s" } ?? "-")")
        switch command {
        case .start:
            if let request { keyboardStart(request, fromLaunch: false, receivedAt: receivedAt) }
        case .stop:
            keyboardStop(request)
        case .cancel:
            keyboardCancel(request)
        }
    }

    private func keyboardStart(_ request: DictationRequest, fromLaunch: Bool, receivedAt: Date) {
        if let capture, capture.request.id == request.id {
            DiagLog.log("engine", "start id=\(EngineDiag.id(request.id)) duplicate → re-ack")
            publish(.recording, requestID: request.id)
            return
        }
        if let capture {
            let age = Date().timeIntervalSince(capture.startedAt)
            if capture.origin == .keyboard, capture.fromLaunch, !fromLaunch, age < Self.launchAdoptWindow {
                // The keyboard opened the app with a launch request and the app is recording
                // it, but the keyboard came back without adopting it and sent a fresh start.
                // Discarding would throw away what the user already said (and is the likely
                // cause of "the second dictation produces no text"): continue the same capture
                // under the id the keyboard now waits for.
                var adopted = capture
                adopted.request = request
                adopted.fromLaunch = false
                self.capture = adopted
                DiagLog.log("engine", "start id=\(EngineDiag.id(request.id)) while launch capture id=\(EngineDiag.id(capture.request.id)) "
                            + "runs for \(String(format: "%.1f", age))s → continued under the new id, audio kept")
                publish(.recording, requestID: request.id)
                extendSession()
                return
            }
            DiagLog.log("engine", "start id=\(EngineDiag.id(request.id)) discards capture id=\(EngineDiag.id(capture.request.id)) "
                        + "origin=\(capture.origin.rawValue) age=\(String(format: "%.1f", age))s")
            discardCapture(reason: "superseded")
        }
        if let job {
            DiagLog.log("engine", "start id=\(EngineDiag.id(request.id)) cancels processing of id=\(EngineDiag.id(job.request.id))")
            cancelJob()
        }

        if !isSessionActive {
            // Reachable when the app is open without a session (e.g. dictating into a field
            // inside Scriber). Only the foreground may start the microphone.
            if UIApplication.shared.applicationState == .active, micPermission == .granted {
                startSession()
            }
            guard isSessionActive else {
                DiagLog.log("engine", "start id=\(EngineDiag.id(request.id)) rejected: no session (app=\(EngineDiag.appState))")
                fail(request, origin: .keyboard, message: "請點一下重新啟動 Scriber", retryable: false, deleteURL: nil)
                return
            }
        }
        if recorder.isInterrupted {
            DiagLog.log("engine", "start id=\(EngineDiag.id(request.id)) rejected: audio interrupted")
            fail(request, origin: .keyboard, message: "麥克風正被通話或其他 App 使用，結束後再試一次",
                 retryable: false, deleteURL: nil)
            return
        }
        let before = posture
        let started = Date()
        do {
            try makeInputLive(context: "start")
        } catch {
            let foreground = UIApplication.shared.applicationState == .active
            let detail = EngineDiag.error((error as? AudioRecorder.Failure)?.underlying ?? error)
            DiagLog.log("engine", "start id=\(EngineDiag.id(request.id)) microphone failed from posture=\(before.rawValue) "
                        + "app=\(EngineDiag.appState) after \(EngineDiag.millis(since: started))ms: \(detail)")
            if !foreground, before == .keepAlive, AppSettings.shared.standbyMode == .outputOnly {
                let refusal = StandbyMemory.Refusal(at: Date(), osVersion: UIDevice.current.systemVersion, error: detail)
                StandbyMemory.outputOnlyRefusal = refusal
                outputOnlyRefusal = refusal
                DiagLog.log("engine", "outputOnly: iOS refused a background microphone start → behaves like off until retried in Settings")
            }
            // From the background iOS will not start the microphone again: end the session so
            // the keyboard opens the app on the next tap.
            endSession(reason: foreground ? "inputStartFailed" : "backgroundInputRefused")
            fail(request, origin: .keyboard, message: foreground ? "無法開始錄音，請再試一次" : Self.needsAppMessage,
                 retryable: false, deleteURL: nil)
            return
        }
        let inputMillis = EngineDiag.millis(since: started)
        do {
            try beginCapture(request, origin: .keyboard, fromLaunch: fromLaunch, receivedAt: receivedAt)
        } catch {
            DiagLog.log("engine", "start id=\(EngineDiag.id(request.id)) clip file failed \(EngineDiag.error(error))")
            fail(request, origin: .keyboard, message: "無法開始錄音，請再試一次", retryable: false, deleteURL: nil)
            return
        }
        DiagLog.log("engine", "recording id=\(EngineDiag.id(request.id)) from=\(before.rawValue) inputReadyMs=\(inputMillis) "
                    + "sinceCommandMs=\(EngineDiag.millis(since: receivedAt)) launch=\(fromLaunch) app=\(EngineDiag.appState)")
        extendSession()
        if fromLaunch { autoReturnIfNeeded() }
    }

    private func keyboardStop(_ request: DictationRequest?) {
        if let capture, request == nil || request?.id == capture.request.id {
            var final = capture.request
            if let request {
                // Slide-up translate is only known at release.
                final.mode = request.mode
                final.fieldHint = request.fieldHint
                if request.selectedText != nil { final.selectedText = request.selectedText }
            }
            finishCapture(final)
            return
        }
        guard let request else { return }
        if let kept, kept.request.id == request.id, job == nil, capture == nil {
            DiagLog.log("engine", "stop id=\(EngineDiag.id(request.id)) → retry on kept audio")
            var retry = kept.request
            retry.mode = request.mode
            runPipeline(url: kept.url, request: retry, origin: .keyboard)
            return
        }
        if shared.requestID == request.id, shared.phase != .recording, shared.phase != .idle {
            DiagLog.log("engine", "stop id=\(EngineDiag.id(request.id)) duplicate (state=\(shared.phase.rawValue))")
            return // already processing / published: a duplicate stop
        }
        // A stop for a request this process knows nothing about must not overwrite the state of
        // the one that is running: the keyboard waiting for that one would lose track of it.
        if let current = capture?.request ?? job?.request {
            DiagLog.log("engine", "stop id=\(EngineDiag.id(request.id)) ignored: id=\(EngineDiag.id(current.id)) is "
                        + "\(capture != nil ? "recording" : "processing")")
            return
        }
        DiagLog.log("engine", "stop id=\(EngineDiag.id(request.id)) for an unknown request (state=\(shared.phase.rawValue)/\(EngineDiag.id(shared.requestID)))")
        fail(request, origin: .keyboard, message: "沒有收到這段錄音，請再說一次", retryable: false, deleteURL: nil)
    }

    private func keyboardCancel(_ request: DictationRequest?) {
        if let capture, request == nil || request?.id == capture.request.id {
            discardCapture(reason: "keyboardCancel")
            phase = .idle
            publish(.idle, requestID: capture.request.id)
            settleAudioAfterCapture(context: "cancel")
            endKeyboardSession()
        } else if let job, request == nil || request?.id == job.request.id {
            DiagLog.log("engine", "cancel id=\(EngineDiag.id(job.request.id)) while processing")
            cancelJob()
            phase = .idle
            publish(.idle, requestID: request?.id)
            endKeyboardSession()
        } else if let kept, request?.id == kept.request.id {
            DiagLog.log("engine", "cancel id=\(EngineDiag.id(kept.request.id)) drops kept audio")
            files.delete(kept.url)
            self.kept = nil
            canRetry = false
            publish(.idle, requestID: request?.id)
            endKeyboardSession()
        } else {
            DiagLog.log("engine", "cancel id=\(EngineDiag.id(request?.id)) ignored: nothing in flight for it")
        }
    }

    // MARK: Capture

    private func beginCapture(_ request: DictationRequest, origin: Origin, fromLaunch: Bool = false,
                              receivedAt: Date = Date()) throws {
        if let kept { files.delete(kept.url); self.kept = nil }
        canRetry = false
        let url = try recorder.beginClip(baseURL: files.newClipBaseURL())
        let capture = Capture(request: request, origin: origin, url: url, startedAt: Date(),
                              fromLaunch: fromLaunch, receivedAt: receivedAt)
        self.capture = capture
        phase = .recording
        level = 0
        lastActivityAt = Date()
        if origin == .keyboard { publish(.recording, requestID: request.id) }

        maxDurationWork?.cancel()
        let token = capture.token
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let capture = self.capture, capture.token == token else { return }
                DiagLog.log("engine", "max duration reached id=\(EngineDiag.id(capture.request.id))")
                self.finishCapture(capture.request)
            }
        }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maximumRecordingSeconds, execute: work)
    }

    private func finishCapture(_ request: DictationRequest) {
        guard let capture else { return }
        maxDurationWork?.cancel()
        self.capture = nil
        let clip = recorder.endClip()
        channel.writeLevel(0)
        level = 0
        lastActivityAt = Date()
        let commandToClip = Int(capture.startedAt.timeIntervalSince(capture.receivedAt) * 1000)
        if let clip {
            let toSignal = clip.timing.firstSignalMillis.map { String(commandToClip + $0) } ?? "-"
            DiagLog.log("engine", "capture end id=\(EngineDiag.id(request.id)) origin=\(capture.origin.rawValue) "
                        + "dur=\(String(format: "%.2f", clip.spokenDuration))s file=\(String(format: "%.2f", clip.fileDuration))s "
                        + "peak=\(String(format: "%.2f", clip.peakLevel)) \(clip.timing.summary) "
                        + "commandToClipMs=\(commandToClip) commandToSignalMs=\(toSignal)")
        } else {
            DiagLog.log("engine", "capture end id=\(EngineDiag.id(request.id)) produced no file")
        }

        guard let clip else {
            fail(request, origin: capture.origin, message: "錄音失敗，請再試一次", retryable: false, deleteURL: capture.url)
            settleAudioAfterCapture(context: "captureEnd")
            return
        }
        if clip.spokenDuration < Self.minimumSpeechSeconds {
            fail(request, origin: capture.origin, message: "說話時間太短", retryable: false, deleteURL: clip.url)
            settleAudioAfterCapture(context: "captureEnd")
            return
        }
        if clip.peakLevel < Self.silenceLevel {
            fail(request, origin: capture.origin, message: "沒有聽到聲音", retryable: false, deleteURL: clip.url)
            settleAudioAfterCapture(context: "captureEnd")
            return
        }
        // Pipeline first: a standby that cannot settle then ends *after* the job instead of
        // killing the heartbeat while the keyboard waits for the result.
        lastClipSeconds = clip.spokenDuration
        runPipeline(url: clip.url, request: request, origin: capture.origin)
        settleAudioAfterCapture(context: "captureEnd")
    }

    private func discardCapture(reason: String) {
        maxDurationWork?.cancel()
        let timing = recorder.discardClip()
        if let capture {
            DiagLog.log("engine", "capture discarded id=\(EngineDiag.id(capture.request.id)) reason=\(reason) \(timing?.summary ?? "")")
        }
        capture = nil
        channel.writeLevel(0)
        level = 0
        lastActivityAt = Date()
    }

    // MARK: Audio posture

    /// Input running and unmuted. Always allowed in the foreground; from the background only
    /// if iOS lets this process start (or unmute) the microphone — what the standby modes test.
    private func makeInputLive(context: String) throws {
        if recorder.isRunning, !recorder.isInterrupted {
            try recorder.setInputMuted(false, context: context)
        } else {
            try recorder.activateSession(context: context)
            recorder.stopEngine(context: context) // clean restart if an interruption left it half-alive
            try recorder.startEngine(context: context)
            try recorder.setInputMuted(false, context: context)
        }
        if recorder.isKeepAliveRunning { recorder.stopKeepAlive(context: context) }
        posture = .live
    }

    /// The capture is over: give the microphone back (no session) or settle into standby.
    private func settleAudioAfterCapture(context: String) {
        if isSessionActive {
            enterStandbyIdle(context: context)
        } else {
            releaseAudioIfIdle()
        }
    }

    /// Between dictations in a standby session: the idle posture of the current mode.
    private func enterStandbyIdle(context: String) {
        guard isSessionActive, capture == nil else { return }
        let mode = effectiveStandbyMode
        switch mode {
        case .off:
            return // one-shot: the input stays live until the session ends
        case .mutedInput:
            if posture == .muted, recorder.isInputMuted, recorder.isRunning { return }
            if posture == .keepAlive {
                // Switched from .outputOnly while idle: the input has to start first.
                guard UIApplication.shared.applicationState == .active else {
                    endSessionWhenIdle(reason: "modeSwitchInBackground")
                    return
                }
                do { try makeInputLive(context: context) } catch {
                    endSessionWhenIdle(reason: "modeSwitchFailed")
                    return
                }
            }
            do {
                // Also fine while an interruption has stopped the engine: the flag belongs to
                // the process, so the engine comes back muted.
                try recorder.setInputMuted(true, context: context)
                posture = .muted
            } catch {
                posture = .live // still reachable; only the orange indicator stays on
            }
        case .outputOnly:
            if posture == .keepAlive, recorder.isKeepAliveRunning, !recorder.isRunning { return }
            let activity = BackgroundActivity(name: "Scriber.standby")
            defer { activity.end() }
            // A muted flag means nothing with the input off; the next start begins clean.
            try? recorder.setInputMuted(false, context: context)
            do {
                try recorder.enterKeepAlive(StandbyMemory.keepAliveCategory, context: context)
                posture = .keepAlive
            } catch {
                recorder.stopEngine(context: context)
                if recorder.isInterrupted {
                    posture = .keepAlive // revived by the tick / interruption end
                } else {
                    DiagLog.log("engine", "standby keep-alive could not start → standby ends")
                    posture = .keepAlive
                    endSessionWhenIdle(reason: "keepAliveFailed")
                    return
                }
            }
        }
        DiagLog.log("engine", "standby idle mode=\(mode.rawValue) posture=\(posture.rawValue) ctx=\(context) "
                    + "expiresIn=\(expiresInText) \(recorder.snapshot)")
    }

    /// Brings the current posture's audio back after an interruption, reset or route change.
    private func reviveAudio(context: String) -> Bool {
        let ok: Bool
        switch posture {
        case .released:
            return true
        case .keepAlive:
            ok = recorder.restartKeepAlive(StandbyMemory.keepAliveCategory, context: context)
        case .live, .muted:
            ok = recorder.restart(context: context)
            if ok, posture == .muted, capture == nil { try? recorder.setInputMuted(true, context: context) }
        }
        DiagLog.log("engine", "revive posture=\(posture.rawValue) ok=\(ok) ctx=\(context) app=\(EngineDiag.appState)")
        if ok { interruptedSince = nil }
        return ok
    }

    private var audioHealthy: Bool {
        switch posture {
        case .released: return true
        case .keepAlive: return recorder.isKeepAliveRunning
        case .live, .muted: return recorder.isRunning
        }
    }

    private func releaseAudio(context: String) {
        let wasHolding = posture != .released || recorder.isRunning || recorder.isKeepAliveRunning
        recorder.stopKeepAlive(context: context)
        recorder.stopEngine(context: context)
        // The next foreground start must begin unmuted.
        try? recorder.setInputMuted(false, context: context)
        if wasHolding { recorder.deactivateSession(context: context) }
        posture = .released
    }

    /// Outside a session the microphone is released as soon as nothing records.
    private func releaseAudioIfIdle() {
        guard !isSessionActive, capture == nil else { return }
        releaseAudio(context: "idle")
    }

    // MARK: Auto-return

    /// Right after the launch request started recording: open the app the user picked.
    /// See AutoReturn.swift for why this is a user-picked app and not the real host.
    private func autoReturnIfNeeded() {
        guard let context = launchContext else { return }
        launchContext = nil
        let since = EngineDiag.millis(since: context.at)
        guard AppSettings.shared.autoReturn else {
            DiagLog.log("app", "autoReturn skip: off")
            return
        }
        guard context.fromOtherApp else {
            DiagLog.log("app", "autoReturn skip: keyboard used inside Scriber")
            return
        }
        guard let target = AutoReturnCatalog.selected else {
            DiagLog.log("app", "autoReturn skip: no app chosen in Settings")
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            DiagLog.log("app", "autoReturn skip: not in front (app=\(EngineDiag.appState))")
            return
        }
        autoReturnStatus = .returning(appName: target.name)
        DiagLog.log("app", "autoReturn attempt target=\(target.id) verified=\(target.verified) sinceURLms=\(since)")
        let started = Date()
        UIApplication.shared.open(target.url, options: [:]) { [weak self] opened in
            Task { @MainActor in
                DiagLog.log("app", "autoReturn result target=\(target.id) opened=\(opened) "
                            + "ms=\(EngineDiag.millis(since: started)) app=\(EngineDiag.appState)")
                if !opened { self?.autoReturnStatus = .failed(appName: target.name) }
            }
        }
    }

    // MARK: Pipeline

    private func runPipeline(url: URL, request: DictationRequest, origin: Origin) {
        cancelJob()
        kept = nil
        canRetry = false
        lastErrorMessage = nil
        phase = .processing
        if origin == .keyboard { publish(.processing, requestID: request.id) }

        let settings = AppSettings.shared
        let sizeKB = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1024
        DiagLog.log("pipe", "start id=\(EngineDiag.id(request.id)) origin=\(origin.rawValue) mode=\(request.mode.rawValue) "
                    + "stt=\(settings.sttProvider.rawValue) polish=\(settings.polishProvider.rawValue) audioKB=\(sizeKB)")
        let started = Date()
        let pipeline = DictationPipeline()
        let task = Task { [weak self] in
            let activity = BackgroundActivity(name: "Scriber.dictation")
            defer { activity.end() }
            do {
                let result = try await pipeline.run(audioFile: url, request: request)
                self?.pipelineSucceeded(result, request: request, url: url, started: started)
            } catch {
                self?.pipelineFailed(error, request: request, url: url, started: started)
            }
        }
        job = Job(request: request, origin: origin, url: url, task: task)
    }

    private func pipelineSucceeded(_ result: PipelineResult, request: DictationRequest, url: URL, started: Date) {
        guard let job, job.request.id == request.id, job.url == url else {
            DiagLog.log("pipe", "done id=\(EngineDiag.id(request.id)) dropped (cancelled or superseded)")
            files.delete(url) // cancelled or superseded
            return
        }
        self.job = nil
        files.delete(url)
        lastActivityAt = Date()
        let text = result.finalText
        DiagLog.log("pipe", "done id=\(EngineDiag.id(request.id)) stt=\(result.sttProvider.rawValue) polish=\(result.polishProvider.rawValue) "
                    + "sttMs=\(result.sttMillis) polishMs=\(result.polishMillis) totalMs=\(EngineDiag.millis(since: started)) "
                    + "outChars=\(text.count)")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(request, origin: job.origin, message: ProviderError.emptyResult.errorDescription ?? "沒有辨識到內容",
                 retryable: false, deleteURL: nil)
            return
        }
        UsageStats.record(text: text, speakingSeconds: lastClipSeconds)
        lastResult = result
        lastErrorMessage = nil
        phase = .done
        if AppSettings.shared.saveHistory {
            HistoryStore.shared.add(HistoryItem(
                mode: request.mode, rawTranscript: result.rawTranscript, finalText: text,
                sttProvider: result.sttProvider, polishProvider: result.polishProvider,
                totalMillis: Int(Date().timeIntervalSince(started) * 1000)))
        }
        if job.origin == .keyboard {
            publish(.done, requestID: request.id, resultText: text)
            endKeyboardSession()
        }
    }

    private func pipelineFailed(_ error: Error, request: DictationRequest, url: URL, started: Date) {
        guard let job, job.request.id == request.id, job.url == url else {
            files.delete(url)
            return
        }
        self.job = nil
        lastActivityAt = Date()
        if Self.isCancellation(error) {
            DiagLog.log("pipe", "cancelled id=\(EngineDiag.id(request.id)) ms=\(EngineDiag.millis(since: started))")
            files.delete(url)
            phase = .idle
            if job.origin == .keyboard { publish(.idle, requestID: request.id); endKeyboardSession() }
            return
        }
        let retryable = Self.isRetryable(error)
        if retryable { kept = (url, request, job.origin) }
        log.error("pipeline failed retryable=\(retryable, privacy: .public): \(String(describing: error), privacy: .private)")
        DiagLog.log("pipe", "failed id=\(EngineDiag.id(request.id)) type=\(EngineDiag.errorType(error)) retryable=\(retryable) "
                    + "ms=\(EngineDiag.millis(since: started))")
        fail(request, origin: job.origin, message: Self.message(for: error), retryable: retryable,
             deleteURL: retryable ? nil : url)
    }

    private func cancelJob() {
        guard let job else { return }
        job.task.cancel()
        files.delete(job.url)
        self.job = nil
    }

    private func fail(_ request: DictationRequest, origin: Origin, message: String, retryable: Bool, deleteURL: URL?) {
        files.delete(deleteURL)
        canRetry = retryable
        lastErrorMessage = message
        phase = .failed
        if origin == .keyboard {
            publish(.failed, requestID: request.id, errorMessage: message, retryable: retryable)
            endKeyboardSession(keepForRetry: retryable)
        } else {
            DiagLog.log("engine", "in-app failed id=\(EngineDiag.id(request.id)) msg=\"\(message)\" retryable=\(retryable)")
        }
    }

    /// A keyboard request is finished (done, failed or cancelled).
    /// One-shot: release the microphone now; the next mic tap opens the app again (after a
    /// retryable failure the app stays a minute so "retry" can still reach it).
    /// Standby: settle into the idle posture and stay reachable for `standbyMinutes`.
    private func endKeyboardSession(keepForRetry: Bool = false) {
        guard isSessionActive, capture == nil else { return }
        if let reason = pendingSessionEnd {
            endSession(reason: reason)
            return
        }
        switch effectiveStandbyMode {
        case .off:
            if keepForRetry {
                sessionExpiresAt = Date().addingTimeInterval(Self.retryWindowSeconds)
                writeShared()
                DiagLog.log("engine", "one-shot: session kept \(Int(Self.retryWindowSeconds))s for retry")
            } else {
                endSession(reason: "oneShotDone")
            }
        case .mutedInput, .outputOnly:
            enterStandbyIdle(context: "requestDone")
            guard isSessionActive else { return }
            extendSession()
            DiagLog.log("engine", "standby continues expiresIn=\(expiresInText)")
        }
    }

    // MARK: Errors

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case ProviderError.cancelled = error { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    /// Network and server-side failures keep the audio for retry; anything the user must fix
    /// (missing/invalid key, bad request, nothing recognized) does not.
    static func isRetryable(_ error: Error) -> Bool {
        if let provider = error as? ProviderError {
            switch provider {
            // Retrying cannot help when the file itself is unreadable (ScriberCore's audioUnreadableCode).
            case .network(let code): return code != "audio-file-unreadable"
            case .http(let status, _): return status == 408 || status == 429 || status >= 500
            default: return false
            }
        }
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// Pipeline errors (ProviderError, PolishError, …) carry zh-Hant `errorDescription`s by contract.
    static func message(for error: Error) -> String {
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return "網路連線失敗，請稍後再試" }
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty { return text }
        return "處理失敗，請再試一次"
    }

    // MARK: Heartbeat + shared state

    private func extendSession() {
        guard isSessionActive else { return }
        let seconds = effectiveStandbyMode == .off
            ? Self.idleSessionSeconds
            : TimeInterval(max(1, AppSettings.shared.standbyMinutes) * 60)
        sessionExpiresAt = Date().addingTimeInterval(seconds)
        writeShared()
    }

    private var expiresInText: String {
        sessionExpiresAt.map { "\(Int($0.timeIntervalSinceNow))s" } ?? "-"
    }

    /// A `.done` from an earlier request can no longer be inserted once the keyboard opened the
    /// app for a new one (its pending request changed), so do not leave dictated text behind.
    private func clearStaleResult() {
        guard shared.resultText != nil || shared.phase == .done else { return }
        shared.phase = .idle
        shared.requestID = nil
        shared.resultText = nil
        shared.errorMessage = nil
        sharedRetryable = false
    }

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { writeShared(); return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        lastTick = Date()
        writeShared()
    }

    private func tick() {
        guard isSessionActive else { return }
        let now = Date()
        let gap = now.timeIntervalSince(lastTick)
        lastTick = now
        if gap > 5 {
            // Timers do not fire while the process is suspended: the keyboard saw no heartbeat.
            DiagLog.log("engine", "heartbeat resumed after a \(Int(gap))s gap: the process was suspended "
                        + "(posture=\(posture.rawValue) app=\(EngineDiag.appState))")
        }
        let busy = capture != nil || job != nil

        if let reason = pendingSessionEnd, !busy {
            endSession(reason: reason)
            return
        }
        if let expires = sessionExpiresAt, now >= expires, !busy {
            endSession(reason: "expired")
            return
        }
        if recorder.isInterrupted {
            let since = interruptedSince ?? now
            interruptedSince = since
            let age = now.timeIntervalSince(since)
            // The interruption may end without an `.ended` notification (common for mixable
            // sessions). Probe every few seconds; give up after the grace period.
            var resumed = false
            if age >= 3, now.timeIntervalSince(lastResumeProbe) >= 5 {
                lastResumeProbe = now
                resumed = reviveAudio(context: "probe")
            }
            if resumed {
                interruptedSince = nil
            } else if age > Self.interruptionGrace, !busy {
                endSession(reason: "interruptionTooLong")
                return
            }
        } else if !audioHealthy, pendingSessionEnd == nil {
            DiagLog.log("engine", "audio not running in posture=\(posture.rawValue) → restart")
            if !reviveAudio(context: "tick") {
                endSessionWhenIdle(reason: "audioStopped")
                if !isSessionActive { return }
            }
        }
        if (shared.phase == .done || shared.phase == .failed),
           now.timeIntervalSince(sharedPhaseSince) > Self.resultRetention, !busy {
            publish(.idle, requestID: nil)
            return
        }
        writeShared()
    }

    private func publish(_ phase: SessionPhase, requestID: String?, resultText: String? = nil,
                         errorMessage: String? = nil, retryable: Bool = false) {
        shared.phase = phase
        shared.requestID = requestID
        shared.resultText = resultText
        shared.errorMessage = errorMessage
        sharedRetryable = retryable
        sharedPhaseSince = Date()
        writeShared()
        DiagLog.log("engine", "state \(phase.rawValue) id=\(EngineDiag.id(requestID)) alive=\(isSessionActive) "
                    + "retryable=\(retryable)\(errorMessage.map { " msg=\"\($0)\"" } ?? "")")
    }

    private func writeShared() {
        shared.heartbeat = isSessionActive ? Date() : .distantPast
        shared.expiresAt = isSessionActive ? sessionExpiresAt : nil
        channel.writeState(shared, retryable: sharedRetryable)
    }

    // MARK: System events

    private func handle(_ event: AudioRecorder.Event) {
        DiagLog.log("engine", "audio event \(event) session=\(isSessionActive) posture=\(posture.rawValue) capture=\(capture != nil)")
        switch event {
        case .interruptionBegan:
            interruptedSince = Date()
            // Keep what was said before the call/Siri took the microphone.
            if let capture { finishCapture(capture.request) }
        case .interruptionEnded:
            interruptedSince = nil
            guard isSessionActive else { return }
            if !reviveAudio(context: "interruptionEnded") {
                log.error("could not resume after interruption")
                endSessionWhenIdle(reason: "resumeAfterInterruptionFailed")
            }
        case .engineLost:
            if let capture { finishCapture(capture.request) }
            if isSessionActive, posture != .keepAlive, !reviveAudio(context: "engineLost") {
                endSessionWhenIdle(reason: "inputLost")
            }
        case .keepAliveLost:
            if isSessionActive, posture == .keepAlive, !reviveAudio(context: "keepAliveLost") {
                endSessionWhenIdle(reason: "keepAliveLost")
            }
        case .mediaServicesReset:
            if let capture { finishCapture(capture.request) }
            if isSessionActive, !reviveAudio(context: "mediaServicesReset") {
                endSessionWhenIdle(reason: "mediaServicesReset")
            }
        }
    }

    private func appDidBecomeActive() {
        refreshMicPermission()
        DiagLog.log("app", "didBecomeActive pendingStart=\(pendingSessionStart) session=\(isSessionActive) "
                    + "posture=\(posture.rawValue) healthy=\(audioHealthy) mic=\(micPermission)")
        if pendingSessionStart {
            startSession()
        } else if isSessionActive, !audioHealthy || recorder.isInterrupted {
            // In front again: the one moment a stopped microphone can surely be restarted.
            if !reviveAudio(context: "didBecomeActive") { endSessionWhenIdle(reason: "reviveFailedInForeground") }
        }
    }

    private func logLifecycle(_ event: String) {
        DiagLog.log("app", "\(event) session=\(isSessionActive) posture=\(posture.rawValue) phase=\(phase.rawValue) "
                    + "capture=\(capture != nil) job=\(job != nil) expiresIn=\(expiresInText) \(recorder.snapshot)")
    }

    /// Returns true if permission is granted. Otherwise asks (once) and calls `then` on success.
    private func ensurePermission(then retry: @escaping () -> Void) -> Bool {
        refreshMicPermission()
        switch micPermission {
        case .granted:
            return true
        case .denied:
            lastErrorMessage = "麥克風權限未開啟，請到「設定」>「Scriber」開啟麥克風"
            return false
        case .undetermined:
            Task { [weak self] in
                guard let self else { return }
                if await self.requestMicPermission() {
                    retry()
                } else {
                    self.lastErrorMessage = "需要麥克風權限才能把說的話轉成文字"
                }
            }
            return false
        }
    }
}
