import AVFoundation
import UIKit
import os
import ScriberShared

/// Owns AVAudioSession, the input AVAudioEngine and the silent keep-alive engine.
///
/// iOS refuses to *start* microphone I/O from the background (`'!rec'`
/// AVAudioSessionErrorCodeCannotStartRecording, or `kAUStartIO` failing with `'what'`), but lets
/// an input that was started in the foreground keep running, and running audio I/O is what keeps
/// a `UIBackgroundModes: audio` app alive. The standby strategies (see `DictationEngine`) differ in
/// what they leave running between dictations:
///   - live input (one-shot session, today's behaviour),
///   - live input with the app's input muted (`AVAudioApplication.setInputMuted`),
///   - no input at all, only a silent output engine (`SilentOutput`).
///
/// Every session/engine transition is written to `DiagLog` ("rec") with its timing and, on
/// failure, the exact error domain and code.
@MainActor
final class AudioRecorder {
    enum Event {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        /// The input engine stopped by itself (route/format change) and could not be restarted.
        case engineLost
        /// The keep-alive engine stopped by itself and could not be restarted.
        case keepAliveLost
        case mediaServicesReset
    }

    enum Failure: Error, LocalizedError {
        case session(Error)
        case noInput
        case engine(Error)
        case mute(Error)

        var errorDescription: String? {
            switch self {
            case .session: return "無法啟動麥克風，可能正被其他 App 或通話使用"
            case .noInput: return "找不到可用的麥克風"
            case .engine: return "麥克風啟動失敗，請再試一次"
            case .mute: return "無法打開麥克風，請再試一次"
            }
        }

        /// The system error behind it, for the diagnostic log.
        var underlying: Error? {
            switch self {
            case .session(let error), .engine(let error), .mute(let error): return error
            case .noInput: return nil
            }
        }
    }

    /// The category the session sits in while the `.outputOnly` standby is idle.
    enum KeepAliveCategory: String, CaseIterable {
        /// `.playback` + `.mixWithOthers`: no recording-capable category while idle, the same idle
        /// category Typeless was observed in. A start switches to play-and-record first.
        case playback
        /// Stay in `.playAndRecord` (mixable) and only stop the input engine; a start is then
        /// a single engine start with no category change (Dictus's "split engines").
        case playAndRecord
    }

    let capture = CaptureBuffer()
    var onEvent: ((Event) -> Void)?

    private let log = Logger(subsystem: "com.geekaz.Scriber", category: "recorder")
    private var engine = AVAudioEngine()
    private let keepAlive = SilentOutput()
    private var observers: [NSObjectProtocol] = []
    private var configObserver: NSObjectProtocol?
    private(set) var isInterrupted = false
    /// True between `startEngine` and `stopEngine`. A configuration change restarts the input
    /// only while it is wanted: after a deliberate stop (keep-alive standby, session end) a
    /// category change must not quietly turn the microphone back on.
    private var wantsInput = false

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })
        observeConfigurationChanges()
        keepAlive.onLost = { [weak self] in self?.onEvent?(.keepAliveLost) }
    }

    /// The input engine (the microphone) is running.
    var isRunning: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic { return fakeMic != nil }
        #endif
        return engine.isRunning
    }

    var isKeepAliveRunning: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic { return fakeKeepAlive }
        #endif
        return keepAlive.isRunning
    }

    var isInputMuted: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic { return fakeMuted.value }
        #endif
        return AVAudioApplication.shared.isInputMuted
    }

    /// One-line snapshot for the log.
    var snapshot: String {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic {
            return "fakeMic input=\(isRunning) muted=\(isInputMuted) keepAlive=\(isKeepAliveRunning)"
        }
        #endif
        let session = AVAudioSession.sharedInstance()
        return "cat=\(EngineDiag.category(session.category)) opts=\(EngineDiag.options(session.categoryOptions)) "
            + "input=\(engine.isRunning) muted=\(isInputMuted) keepAlive=\(keepAlive.isRunning) "
            + "interrupted=\(isInterrupted) otherAudio=\(session.isOtherAudioPlaying) \(EngineDiag.route(session.currentRoute))"
    }

    // MARK: Session

    /// Play-and-record, mixable, then active. In the foreground this always may start the
    /// microphone; from the background iOS decides.
    func activateSession(context: String) throws {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic { return }
        #endif
        let session = AVAudioSession.sharedInstance()
        do {
            // .mixWithOthers: never pause or duck the user's music/podcast.
            // .allowBluetoothA2DP (not HFP): AirPods keep high-quality output and their media
            // controls; recording uses the built-in mic. .defaultToSpeaker: no earpiece routing.
            try setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker],
                            context: context)
            // Without this, iOS mutes haptics and system sounds of the recording app — and the
            // keyboard's haptics while our input is live.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            // A ringing call or alarm alert should not kill the session; answering still does.
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            try setActive(context: context)
        } catch {
            log.error("session activation failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.session(error)
        }
    }

    /// The idle category of the `.outputOnly` standby, then active.
    func activateKeepAliveSession(_ category: KeepAliveCategory, context: String) throws {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic { return }
        #endif
        do {
            switch category {
            case .playback:
                try setCategory(.playback, options: [.mixWithOthers], context: context)
                try setActive(context: context)
            case .playAndRecord:
                try activateSession(context: context)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.session(error)
        }
    }

    func deactivateSession(context: String) {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic { DiagLog.log("rec", "deactivate (fake) ctx=\(context)"); return }
        #endif
        let started = Date()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            DiagLog.log("rec", "deactivate ok ms=\(EngineDiag.millis(since: started)) ctx=\(context)")
        } catch {
            DiagLog.log("rec", "deactivate failed \(EngineDiag.error(error)) ctx=\(context)")
        }
    }

    private func setCategory(_ category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions,
                             context: String) throws {
        let session = AVAudioSession.sharedInstance()
        let name = EngineDiag.category(category)
        if session.category == category, session.mode == .default, session.categoryOptions == options {
            return // unchanged: setting it again can still bounce the route
        }
        let started = Date()
        do {
            try session.setCategory(category, mode: .default, options: options)
            DiagLog.log("rec", "category \(name) opts=\(EngineDiag.options(options)) ok ms=\(EngineDiag.millis(since: started)) ctx=\(context) app=\(EngineDiag.appState)")
        } catch {
            DiagLog.log("rec", "category \(name) opts=\(EngineDiag.options(options)) failed \(EngineDiag.error(error)) ctx=\(context) app=\(EngineDiag.appState)")
            throw error
        }
    }

    private func setActive(context: String) throws {
        let session = AVAudioSession.sharedInstance()
        let started = Date()
        do {
            try session.setActive(true)
            DiagLog.log("rec", "activate ok ms=\(EngineDiag.millis(since: started)) cat=\(EngineDiag.category(session.category)) otherAudio=\(session.isOtherAudioPlaying) ctx=\(context) app=\(EngineDiag.appState)")
        } catch {
            DiagLog.log("rec", "activate failed \(EngineDiag.error(error)) cat=\(EngineDiag.category(session.category)) ctx=\(context) app=\(EngineDiag.appState)")
            throw error
        }
    }

    // MARK: Input engine

    /// Installs the tap and starts the input engine. Safe to call when already running.
    func startEngine(context: String) throws {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic {
            if fakeMic == nil { capture.resetInput(); fakeMic = Self.startFakeMic(capture, muted: fakeMuted) }
            isInterrupted = false
            DiagLog.log("rec", "input start ok (fake) ctx=\(context) app=\(EngineDiag.appState)")
            return
        }
        #endif
        wantsInput = true
        if engine.isRunning { return }
        let started = Date()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            wantsInput = false
            DiagLog.log("rec", "input start failed noInput sr=\(format.sampleRate) ch=\(format.channelCount) ctx=\(context) app=\(EngineDiag.appState)")
            throw Failure.noInput
        }
        input.removeTap(onBus: 0)
        capture.resetInput()
        // format nil = the node's current hardware format; passing a mismatching explicit
        // format raises an Objective-C exception that Swift cannot catch.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.tapBlock(capture))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            wantsInput = false
            log.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            DiagLog.log("rec", "input start failed \(EngineDiag.error(error)) ms=\(EngineDiag.millis(since: started)) ctx=\(context) app=\(EngineDiag.appState) cat=\(EngineDiag.category(AVAudioSession.sharedInstance().category))")
            throw Failure.engine(error)
        }
        isInterrupted = false
        DiagLog.log("rec", "input start ok ms=\(EngineDiag.millis(since: started)) sr=\(Int(format.sampleRate)) ch=\(format.channelCount) muted=\(isInputMuted) ctx=\(context) app=\(EngineDiag.appState) \(EngineDiag.route())")
    }

    /// Built outside the main actor: the block runs on the engine's tap thread and must not
    /// inherit main-actor isolation (which would trip a runtime isolation assert).
    nonisolated private static func tapBlock(_ capture: CaptureBuffer) -> AVAudioNodeTapBlock {
        { buffer, _ in capture.ingest(buffer) }
    }

    func stopEngine(context: String) {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic {
            if fakeMic != nil { DiagLog.log("rec", "input stop (fake) ctx=\(context)") }
            fakeMic?.cancel(); fakeMic = nil; capture.resetInput()
            return
        }
        #endif
        wantsInput = false
        let wasRunning = engine.isRunning
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        capture.resetInput()
        if wasRunning { DiagLog.log("rec", "input stop ctx=\(context)") }
    }

    /// Activate + clean restart of the input engine (after interruptions and route changes).
    func restart(context: String) -> Bool {
        do {
            try activateSession(context: context)
            stopEngine(context: context)
            try startEngine(context: context)
            return true
        } catch {
            return false
        }
    }

    /// Mutes or unmutes the app's audio input (iOS 17+). The flag belongs to the process and
    /// outlives the engine; it is a no-op when already in the wanted state.
    func setInputMuted(_ muted: Bool, context: String) throws {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic {
            if fakeMuted.value != muted { DiagLog.log("rec", "mute \(muted) ok (fake) ctx=\(context)") }
            fakeMuted.value = muted
            return
        }
        #endif
        let app = AVAudioApplication.shared
        guard app.isInputMuted != muted else { return }
        do {
            try app.setInputMuted(muted)
            DiagLog.log("rec", "mute \(muted) ok input=\(engine.isRunning) ctx=\(context) app=\(EngineDiag.appState)")
        } catch {
            DiagLog.log("rec", "mute \(muted) failed \(EngineDiag.error(error)) ctx=\(context)")
            throw Failure.mute(error)
        }
    }

    // MARK: Keep-alive (silent output)

    /// Starts the silent output engine (no microphone).
    func startKeepAlive(context: String) throws {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic {
            if !fakeKeepAlive { DiagLog.log("rec", "keepAlive start ok (fake) ctx=\(context)") }
            fakeKeepAlive = true
            isInterrupted = false
            return
        }
        #endif
        try keepAlive.start(context: context)
        isInterrupted = false
    }

    func stopKeepAlive(context: String) {
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic {
            if fakeKeepAlive { DiagLog.log("rec", "keepAlive stop (fake) ctx=\(context)") }
            fakeKeepAlive = false
            return
        }
        #endif
        keepAlive.stop(context: context)
    }

    /// Input off, silent output on, in the given idle category. Ordered so that some audio I/O
    /// is running at every step where that is possible:
    ///   - play-and-record idle: start the silent output first, then stop the input;
    ///   - playback idle: stop the input, switch category, start the silent output (a category
    ///     switch would stop an already-running output engine anyway).
    func enterKeepAlive(_ category: KeepAliveCategory, context: String) throws {
        switch category {
        case .playAndRecord:
            try activateKeepAliveSession(.playAndRecord, context: context)
            try startKeepAlive(context: context)
            stopEngine(context: context)
        case .playback:
            stopEngine(context: context)
            try activateKeepAliveSession(.playback, context: context)
            try startKeepAlive(context: context)
        }
    }

    /// Re-establishes the keep-alive after an interruption or a configuration change.
    func restartKeepAlive(_ category: KeepAliveCategory, context: String) -> Bool {
        do {
            try activateKeepAliveSession(category, context: context)
            stopKeepAlive(context: context)
            try startKeepAlive(context: context)
            return true
        } catch {
            return false
        }
    }

    // MARK: Clips

    func beginClip(baseURL: URL) throws -> URL {
        try capture.beginClip(baseURL: baseURL)
    }

    func endClip() -> CapturedClip? {
        capture.endClip()
    }

    @discardableResult
    func discardClip() -> ClipTiming? {
        capture.discardClip()
    }

    // MARK: Permission

    static var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Notifications

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "-"
            log.info("interruption began")
            DiagLog.log("rec", "interruption began reason=\(reason) app=\(EngineDiag.appState) input=\(isRunning) keepAlive=\(isKeepAliveRunning)")
            isInterrupted = true
            onEvent?(.interruptionBegan)
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            log.info("interruption ended resume=\(options.contains(.shouldResume), privacy: .public)")
            DiagLog.log("rec", "interruption ended shouldResume=\(options.contains(.shouldResume)) app=\(EngineDiag.appState)")
            isInterrupted = false
            onEvent?(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
        @unknown default:
            break
        }
    }

    /// The whole audio stack was rebuilt by the system: every engine is invalid.
    private func handleMediaServicesReset() {
        log.error("media services reset")
        DiagLog.log("rec", "media services reset app=\(EngineDiag.appState)")
        #if DEBUG && targetEnvironment(simulator)
        if Self.useFakeMic { onEvent?(.mediaServicesReset); return }
        #endif
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        observeConfigurationChanges()
        capture.resetInput()
        keepAlive.discardEngine()
        onEvent?(.mediaServicesReset)
    }

    private func handleRouteChange(_ note: Notification) {
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let route = EngineDiag.route()
        log.info("route change reason=\(reason, privacy: .public) \(route, privacy: .public)")
        DiagLog.log("rec", "route change reason=\(EngineDiag.routeChangeReason(reason)) \(route) cat=\(EngineDiag.category(AVAudioSession.sharedInstance().category))")
        // AVAudioEngine reports what matters for us (input format change) through
        // AVAudioEngineConfigurationChange; this is for the log.
    }

    private func observeConfigurationChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    /// The input format changed (headset plugged, Bluetooth, sample-rate switch). The engine has
    /// stopped itself; reinstall the tap with the new format and start again. An open clip keeps
    /// going: `CaptureBuffer` rebuilds its converter for the new input format.
    private func handleConfigurationChange() {
        guard wantsInput, !isInterrupted, !engine.isRunning else { return }
        log.info("engine configuration change")
        DiagLog.log("rec", "input configuration change → restart \(EngineDiag.route())")
        engine.inputNode.removeTap(onBus: 0)
        do {
            try startEngine(context: "configChange")
        } catch {
            onEvent?(.engineLost)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator-only stand-in for the microphone, for exercising the session/keyboard flow:
    /// `xcrun simctl spawn <udid> defaults write com.geekaz.Scriber ScriberFakeMic -bool YES`
    /// (or `-ScriberFakeMic YES` at launch). Headless simulators cannot initialize AURemoteIO —
    /// AudioToolbox aborts on an RPC timeout as soon as `inputNode` is touched. The fake mic
    /// honours the input mute (zeros) and the keep-alive is a flag.
    static let useFakeMic = UserDefaults.standard.bool(forKey: "ScriberFakeMic")
    private var fakeMic: DispatchSourceTimer?
    private var fakeKeepAlive = false
    private let fakeMuted = FakeMuteFlag()

    final class FakeMuteFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// 48 kHz mono buffers of a tone whose loudness swells like speech, at the tap's cadence.
    nonisolated private static func startFakeMic(_ capture: CaptureBuffer, muted: FakeMuteFlag) -> DispatchSourceTimer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let frames: AVAudioFrameCount = 1024
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "scriber.fakemic"))
        var phase = 0.0
        var t = 0.0
        timer.setEventHandler {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let data = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = frames
            let silent = muted.value
            for i in 0..<Int(frames) {
                let envelope = 0.02 + 0.25 * max(0, sin(2 * .pi * 0.8 * t))
                data[i] = silent ? 0 : Float(envelope * sin(phase))
                phase += 2 * .pi * 220 / 48_000
                t += 1 / 48_000
            }
            capture.ingest(buffer)
        }
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(Double(frames) / 48_000 * 1e9)))
        timer.resume()
        return timer
    }
    #endif
}
