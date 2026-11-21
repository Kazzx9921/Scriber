import AVFAudio
import Foundation
import UIKit
import ScriberCore
import ScriberShared

/// Experimental in-keyboard capture (`AppSettings.inKeyboardCapture`, iOS 26+): the keyboard
/// records through `WebMicrophone`, assembles a 16 kHz mono WAV in its own temp directory and
/// runs the same `DictationPipeline` the app runs (STT → cleanup → zh-TW), so no app switch is
/// needed at all. Anything that fails *before audio arrives* hands the same tap back to the app
/// path (`Event.fallback`) and puts this path on a cooldown so later taps don't wait for it.
///
/// Lifecycle: the web view exists only from the tap until the capture is stopped or discarded,
/// so there is no hidden microphone session (or orange dot) between dictations and nothing runs
/// while the keyboard is not recording.
@MainActor
final class InKeyboardCapture {
    enum Phase: String { case idle, starting, recording, finishing, processing }

    enum Event {
        /// First audio arrived: the user can talk.
        case listening
        /// Nothing was captured; the caller should serve `request` through the app instead.
        case fallback(DictationRequest, reason: String)
        /// The track ended by itself (call, Siri, another app took the microphone): treat as stop.
        case endedByItself
        case processing
        case finished(DictationRequest, text: String)
        case failed(DictationRequest, message: String, retryable: Bool)
    }

    // MARK: Tuning
    // Start-up budget, in three steps so a slow-but-working cold start (WebKit content process +
    // first AudioContext took ~2 s in the Simulator) is not mistaken for a broken one, while a
    // capture that never delivers is abandoned quickly. Each step's latency is logged.
    /// From the tap to the page script running (web view + content process launch; 2.0–3.0 s
    /// per fresh web view in the iOS 27 Simulator, expected well under 1 s on a device).
    static let pageReadyTimeout: TimeInterval = 4.0
    /// From `scriberStart()` to getUserMedia + AudioContext running (`started`). A denial
    /// arrives as an error long before this.
    static let micStartTimeout: TimeInterval = 2.5
    /// From `started` to the first PCM chunk: "no samples arrive within ~1.5 s".
    static let firstSampleTimeout: TimeInterval = 1.5
    /// Timeouts put the path on cooldown only when they repeat (a one-off slow start is not
    /// worth a 5-minute penalty); hard failures do so at once.
    static let softFailuresBeforeCooldown = 2
    /// Hex measured a ~58 MB footprint with ~118 MB headroom while recording (iPhone 17 Pro,
    /// iOS 27.2); the pipeline adds the OpenCC tables (~2 MB) and the upload body.
    static let requiredHeadroom: UInt64 = 40 * 1_048_576
    /// Same thresholds as the app's recorder (`DictationEngine`).
    static let minimumSpeechSeconds: TimeInterval = 0.3
    static let silenceLevel: Float = 0.12
    static let maximumRecordingSeconds: TimeInterval = 600
    /// After a failure that suggests the technique does not work here (permission, missing
    /// API, WebKit process): long. After repeated timeouts: short.
    static let hardCooldown: TimeInterval = 30 * 60
    static let softCooldown: TimeInterval = 5 * 60

    var onEvent: ((Event) -> Void)?
    private(set) var phase: Phase = .idle
    /// Smoothed level 0...1 for the waveform.
    private(set) var level: Float = 0

    private var request: DictationRequest?
    private var microphone: WebMicrophone?
    private var assembler: CaptureAssembler?
    private var tappedAt = Date.distantPast
    private var pageReadyAt: Date?
    private var micStartedAt: Date?
    private var gotAudio = false
    private var timeout: DispatchWorkItem?
    private var maxDuration: DispatchWorkItem?
    private var stopWait: DispatchWorkItem?
    private var job: Task<Void, Never>?
    /// Audio kept after a network/server failure, for 重試.
    private var kept: (url: URL, request: DictationRequest, duration: TimeInterval)?
    /// The last request counted in `UsageStats`: a dictation is counted once, however it got
    /// there (first run or 重試). The app counts only what its own engine produces, so the two
    /// processes never count the same dictation.
    private var lastCountedID: String?
    private let defaults = AppGroup.defaults

    // MARK: Availability

    /// Why the path can or cannot serve the next tap. `checkKey` reads the keychain (a few ms).
    func availability(hasFullAccess: Bool, checkKey: Bool) -> (available: Bool, reason: String) {
        guard AppSettings.shared.inKeyboardCapture else { return (false, "flag-off") }
        guard #available(iOS 26, *) else { return (false, "ios<26") }
        guard hasFullAccess else { return (false, "no-full-access") }
        let mic = Self.microphonePermission()
        guard mic.effective == "granted" else { return (false, "mic app=\(mic.published ?? "unpublished") own=\(mic.own)") }
        if let until = defaults.object(forKey: Keys.cooldownUntil) as? Date, until > Date() {
            let reason = defaults.string(forKey: Keys.cooldownReason) ?? "?"
            // A permission failure is worth retrying as soon as the app reports a new permission.
            if defaults.string(forKey: Keys.cooldownMic) == mic.published {
                return (false, "cooldown \(Int(until.timeIntervalSinceNow))s after \(reason)")
            }
            clearCooldown()
        }
        let headroom = KBLog.headroomBytes
        if headroom != 0, headroom < Self.requiredHeadroom {
            return (false, String(format: "memory headroom=%.1fMB", Double(headroom) / 1_048_576))
        }
        if checkKey, !Self.sttKeyVisible() { return (false, "no-stt-key-in-shared-keychain") }
        return (true, "ok")
    }

    /// The app's published permission wins; the keyboard's own reading is the fallback (Hex
    /// relied on it on iOS 27.2, where it reported the containing app's permission).
    static func microphonePermission() -> (effective: String, published: String?, own: String) {
        let own: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted: own = "granted"
        case .denied: own = "denied"
        case .undetermined: own = "undetermined"
        @unknown default: own = "unknown"
        }
        let published = SessionChannel.readAppMicrophonePermission()
        return (published ?? own, published, own)
    }

    private static func sttKeyVisible() -> Bool {
        let kind: APIKeyKind
        switch AppSettings.shared.sttProvider {
        case .elevenLabsScribe: kind = .elevenLabs
        case .groqWhisperLarge, .groqWhisperTurbo: kind = .groq
        case .custom: kind = .custom
        }
        return KeychainStore.shared.hasKey(for: kind)
    }

    // MARK: Capture

    func start(_ request: DictationRequest, host: UIView) {
        cancel(reason: "superseded", silently: true)
        discardKept()
        purgeOldClips()
        self.request = request
        phase = .starting
        level = 0
        gotAudio = false
        pageReadyAt = nil
        micStartedAt = nil
        tappedAt = Date()
        KBLog.log("local start id=\(KBLog.id(request.id)) mode=\(request.mode.rawValue) \(KBLog.memory)")
        // The zh-TW tables load lazily; warm them while the user talks.
        Task.detached(priority: .utility) { ZhTW.prewarm() }

        let microphone = WebMicrophone(host: host)
        microphone.onEvent = { [weak self] event in self?.handle(event) }
        self.microphone = microphone
        microphone.start()
        arm(after: Self.pageReadyTimeout) { [weak self] in
            self?.fallBack(reason: "page-not-ready-\(Int(Self.pageReadyTimeout * 1000))ms", hard: false)
        }
    }

    /// The user tapped to finish: keep what was said and run the pipeline.
    func stop() {
        switch phase {
        case .starting:
            // Tapped again before any audio arrived.
            KBLog.log("local stop before first sample id=\(KBLog.id(request?.id)) after \(KBLog.millis(since: tappedAt))ms")
            let request = self.request
            cancel(reason: "stopped-before-audio", silently: true)
            if let request { onEvent?(.failed(request, message: "說話時間太短", retryable: false)) }
        case .recording:
            beginFinishing(reason: "tap")
        default:
            break
        }
    }

    /// Discards everything (cancel button, keyboard dismissed, superseded).
    func cancel(reason: String, silently: Bool = false) {
        guard phase != .idle || microphone != nil else { return }
        if !silently {
            KBLog.log("local cancel id=\(KBLog.id(request?.id)) phase=\(phase.rawValue) reason=\(reason)")
        }
        job?.cancel()
        job = nil
        disarm()
        maxDuration?.cancel()
        stopWait?.cancel()
        if let microphone {
            microphone.onEvent = nil // nothing it says from now on matters
            microphone.stop()
            // Give the page a moment to release the tracks, then drop the view either way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { microphone.tearDown() }
        }
        microphone = nil
        assembler?.discard()
        assembler = nil
        request = nil
        phase = .idle
        level = 0
    }

    /// Re-runs the pipeline on the audio kept after a network/server failure.
    func retry() -> DictationRequest? {
        guard phase == .idle, let kept else { return nil }
        self.kept = nil
        KBLog.log("local retry id=\(KBLog.id(kept.request.id))")
        runPipeline(url: kept.url, request: kept.request, duration: kept.duration)
        return kept.request
    }

    func discardKept() {
        guard let kept else { return }
        try? FileManager.default.removeItem(at: kept.url)
        self.kept = nil
    }

    // MARK: Events from the page

    private func handle(_ event: WebMicrophone.Event) {
        switch event {
        case .ready(let secure, let mediaDevices, let loadMillis):
            KBLog.log("local page ready secure=\(secure) mediaDevices=\(mediaDevices) load=\(loadMillis)ms")
            guard phase == .starting else { return }
            guard secure, mediaDevices else {
                fallBack(reason: "no-getUserMedia secure=\(secure) mediaDevices=\(mediaDevices)", hard: true)
                return
            }
            pageReadyAt = Date()
            arm(after: Self.micStartTimeout) { [weak self] in
                self?.fallBack(reason: "getUserMedia-pending-\(Int(Self.micStartTimeout * 1000))ms", hard: false)
            }
        case .started(let rate, let micMillis, let totalMillis):
            KBLog.log("local mic started rate=\(Int(rate)) getUserMedia=\(micMillis)ms total=\(totalMillis)ms since-tap=\(KBLog.millis(since: tappedAt))ms")
            guard phase == .starting, assembler == nil else { return }
            micStartedAt = Date()
            do {
                assembler = try CaptureAssembler(url: Self.clipDirectory.appendingPathComponent("\(UUID().uuidString).wav"),
                                                 inputRate: rate)
            } catch {
                fallBack(reason: "wav-create-failed \((error as NSError).domain).\((error as NSError).code)", hard: true)
                return
            }
            arm(after: Self.firstSampleTimeout) { [weak self] in
                self?.fallBack(reason: "no-samples-\(Int(Self.firstSampleTimeout * 1000))ms", hard: false)
            }
        case .chunk(let data, let seq):
            guard phase == .starting || phase == .recording || phase == .finishing, let assembler else { return }
            let chunkLevel: Float
            do {
                chunkLevel = try assembler.append(int16LittleEndian: data)
            } catch {
                KBLog.log("local wav write failed \((error as NSError).domain).\((error as NSError).code) chunk=\(seq)")
                if gotAudio { beginFinishing(reason: "write-failed") } else { fallBack(reason: "wav-write-failed", hard: true) }
                return
            }
            level = chunkLevel > level ? chunkLevel : level * 0.75 + chunkLevel * 0.25
            if !gotAudio {
                gotAudio = true
                disarm()
                phase = .recording
                let sinceReady = pageReadyAt.map { " since-ready=\(KBLog.millis(since: $0))ms" } ?? ""
                let sinceMic = micStartedAt.map { " since-mic=\(KBLog.millis(since: $0))ms" } ?? ""
                KBLog.log("local first sample since-tap=\(KBLog.millis(since: tappedAt))ms\(sinceReady)\(sinceMic) \(KBLog.memory)")
                defaults.removeObject(forKey: Keys.softFailures)
                armMaxDuration()
                onEvent?(.listening)
            }
        case .ended:
            KBLog.log("local track ended by itself id=\(KBLog.id(request?.id)) phase=\(phase.rawValue)")
            if phase == .recording { onEvent?(.endedByItself) } else if phase == .starting {
                fallBack(reason: "track-ended-before-audio", hard: false)
            }
        case .stopped(let chunks):
            KBLog.log("local mic released chunks=\(chunks)")
            if phase == .finishing { finishCapture() }
        case .failed(let stage, let name, let message):
            // Name and stage only in the log; WebKit's message can be long but holds no user data.
            KBLog.log("local failure stage=\(stage) name=\(name) message=\(message.prefix(120)) phase=\(phase.rawValue) gotAudio=\(gotAudio)")
            switch phase {
            case .starting:
                fallBack(reason: "\(stage):\(name)", hard: true)
            case .recording:
                beginFinishing(reason: "failure-\(name)") // keep what was said
            case .finishing:
                finishCapture()
            default:
                break
            }
        }
    }

    // MARK: Finishing

    private func beginFinishing(reason: String) {
        guard phase == .recording else { return }
        phase = .finishing
        maxDuration?.cancel()
        KBLog.log("local stop id=\(KBLog.id(request?.id)) reason=\(reason) captured=\(String(format: "%.2f", assembler?.duration ?? 0))s")
        microphone?.stop()
        // The page answers `stopped` after releasing the tracks; don't wait forever for it.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .finishing else { return }
                KBLog.log("local stop: no 'stopped' from the page within 1s, finishing anyway")
                self.finishCapture()
            }
        }
        stopWait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func finishCapture() {
        guard phase == .finishing, let request else { return }
        stopWait?.cancel()
        let microphone = self.microphone
        self.microphone = nil
        microphone?.tearDown() // no web view, no microphone, between dictations
        level = 0
        guard let assembler else {
            phase = .idle
            self.request = nil
            onEvent?(.failed(request, message: "錄音失敗，請再試一次", retryable: false))
            return
        }
        self.assembler = nil
        let duration: TimeInterval
        do {
            duration = try assembler.finish()
        } catch {
            assembler.discard()
            phase = .idle
            self.request = nil
            KBLog.log("local wav finish failed \((error as NSError).domain).\((error as NSError).code)")
            onEvent?(.failed(request, message: "錄音失敗，請再試一次", retryable: false))
            return
        }
        KBLog.log(String(format: "local clip id=%@ duration=%.2fs peak=%.2f chunks=%d", KBLog.id(request.id),
                         duration, assembler.peakLevel, assembler.chunkCount))
        if duration < Self.minimumSpeechSeconds || assembler.peakLevel < Self.silenceLevel {
            assembler.discard()
            phase = .idle
            self.request = nil
            onEvent?(.failed(request, message: duration < Self.minimumSpeechSeconds ? "說話時間太短" : "沒有聽到聲音",
                             retryable: false))
            return
        }
        runPipeline(url: assembler.url, request: request, duration: duration)
    }

    // MARK: Pipeline (same as the app's)

    /// `duration`: length of the clip, for the usage stats.
    private func runPipeline(url: URL, request: DictationRequest, duration: TimeInterval) {
        self.request = request
        phase = .processing
        onEvent?(.processing)
        let started = Date()
        let pipeline = DictationPipeline()
        job = Task { [weak self] in
            do {
                let result = try await pipeline.run(audioFile: url, request: request)
                self?.pipelineSucceeded(result, url: url, request: request, duration: duration, started: started)
            } catch {
                self?.pipelineFailed(error, url: url, request: request, duration: duration)
            }
        }
    }

    private func pipelineSucceeded(_ result: PipelineResult, url: URL, request: DictationRequest,
                                   duration: TimeInterval, started: Date) {
        guard phase == .processing, self.request?.id == request.id else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        job = nil
        phase = .idle
        self.request = nil
        try? FileManager.default.removeItem(at: url)
        let total = KBLog.millis(since: started)
        KBLog.log("local pipeline ok id=\(KBLog.id(request.id)) stt=\(result.sttMillis)ms polish=\(result.polishMillis)ms total=\(total)ms len=\(result.finalText.count) stt=\(result.sttProvider.rawValue) polish=\(result.polishProvider.rawValue) \(KBLog.memory)")
        if AppSettings.shared.saveHistory {
            let item = HistoryItem(mode: request.mode, rawTranscript: result.rawTranscript, finalText: result.finalText,
                                   sttProvider: result.sttProvider, polishProvider: result.polishProvider, totalMillis: total)
            // File I/O under the cross-process lock: off the main thread.
            Task.detached(priority: .utility) { HistoryStore.shared.add(item) }
        }
        if lastCountedID != request.id {
            lastCountedID = request.id
            UsageStats.record(text: result.finalText, speakingSeconds: duration)
        }
        onEvent?(.finished(request, text: result.finalText))
    }

    private func pipelineFailed(_ error: Error, url: URL, request: DictationRequest, duration: TimeInterval) {
        guard phase == .processing, self.request?.id == request.id else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        job = nil
        phase = .idle
        self.request = nil
        if Self.isCancellation(error) {
            try? FileManager.default.removeItem(at: url)
            KBLog.log("local pipeline cancelled id=\(KBLog.id(request.id))")
            return
        }
        let retryable = Self.isRetryable(error)
        if retryable { kept = (url, request, duration) } else { try? FileManager.default.removeItem(at: url) }
        KBLog.log("local pipeline failed id=\(KBLog.id(request.id)) retryable=\(retryable) error=\(Self.describe(error))")
        onEvent?(.failed(request, message: Self.message(for: error), retryable: retryable))
    }

    // MARK: Fallback + cooldown

    private func fallBack(reason: String, hard: Bool) {
        guard phase == .starting, let request else { return }
        let softFailures = hard ? 0 : defaults.integer(forKey: Keys.softFailures) + 1
        var cooldown: TimeInterval = 0
        if hard || softFailures >= Self.softFailuresBeforeCooldown {
            cooldown = hard ? Self.hardCooldown : Self.softCooldown
            defaults.set(Date().addingTimeInterval(cooldown), forKey: Keys.cooldownUntil)
            defaults.set(reason, forKey: Keys.cooldownReason)
            let published = Self.microphonePermission().published
            if let published { defaults.set(published, forKey: Keys.cooldownMic) } else { defaults.removeObject(forKey: Keys.cooldownMic) }
            defaults.removeObject(forKey: Keys.softFailures)
        } else {
            defaults.set(softFailures, forKey: Keys.softFailures)
        }
        KBLog.log("local fallback → app id=\(KBLog.id(request.id)) reason=\(reason) after \(KBLog.millis(since: tappedAt))ms cooldown=\(Int(cooldown))s softFailures=\(softFailures) \(KBLog.memory)")
        cancel(reason: "fallback", silently: true)
        onEvent?(.fallback(request, reason: reason))
    }

    func clearCooldown() {
        defaults.removeObject(forKey: Keys.cooldownUntil)
        defaults.removeObject(forKey: Keys.cooldownReason)
        defaults.removeObject(forKey: Keys.cooldownMic)
        defaults.removeObject(forKey: Keys.softFailures)
    }

    private func arm(after seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        disarm()
        let work = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func disarm() {
        timeout?.cancel()
        timeout = nil
    }

    private func armMaxDuration() {
        maxDuration?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.beginFinishing(reason: "max-duration") }
        }
        maxDuration = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maximumRecordingSeconds, execute: work)
    }

    // MARK: Files

    static var clipDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScriberCapture", isDirectory: true)
    }

    private func purgeOldClips() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Self.clipDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for url in items where url != kept?.url {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: Errors (same rules as the app's DictationEngine)

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case ProviderError.cancelled = error { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let provider = error as? ProviderError {
            switch provider {
            case .network(let code): return code != "audio-file-unreadable" // ScriberCore's audioUnreadableCode (internal)
            case .http(let status, _): return status == 408 || status == 429 || status >= 500
            default: return false
            }
        }
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }

    static func message(for error: Error) -> String {
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return "網路連線失敗，請稍後再試" }
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty { return text }
        return "處理失敗，請再試一次"
    }

    /// Type and code only: server messages can echo what was said.
    private static func describe(_ error: Error) -> String {
        if let provider = error as? ProviderError {
            switch provider {
            case .missingAPIKey(let kind): return "missingAPIKey(\(kind.rawValue))"
            case .http(let status, _): return "http(\(status))"
            case .network(let code): return "network(\(code))"
            case .emptyResult: return "emptyResult"
            case .cancelled: return "cancelled"
            }
        }
        let ns = error as NSError
        return "\(String(describing: type(of: error)))(\(ns.domain).\(ns.code))"
    }

    private enum Keys {
        static let cooldownUntil = "keyboard.localCapture.cooldownUntil"
        static let cooldownReason = "keyboard.localCapture.cooldownReason"
        static let cooldownMic = "keyboard.localCapture.cooldownMicPermission"
        static let softFailures = "keyboard.localCapture.consecutiveTimeouts"
    }
}
