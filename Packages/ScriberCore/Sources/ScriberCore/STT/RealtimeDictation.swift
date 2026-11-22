import Foundation
import ScriberShared

// Real-time transcription used only to have the text ready sooner (iOS 「邊講邊辨識」, docs/PRD.md
// §11): a `RealtimeSTTSession` streams the clip's 16 kHz audio while the clip is recorded to a file
// as usual. Nothing is shown while speaking. At stop exactly one path produces the text: the
// streamed transcript, or — on any real-time failure, an empty transcript, a timeout, or a mode
// that no longer streams — the recorded file through the normal upload, so a dictation is never
// lost. After `RealtimeBackoff.failureLimit` failures in a row the upload is used alone for a while.
//
// The Mac (`DictationController`) follows the same rules with its own live-text bookkeeping.
// Log lines carry ids, reasons, timings and counts only — never text or keys.

/// After `failureLimit` real-time failures in a row, dictations use the upload alone for `pause`
/// seconds (a protocol change on the server must not add a timeout to every dictation). The next
/// success resets it. Thread-safe; one per app process.
public final class RealtimeBackoff: @unchecked Sendable {
    public static let failureLimit = 3
    public static let pause: TimeInterval = 600

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var failures = 0
    private var pausedUntil: Date?

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Seconds until real time is tried again; nil when it may be tried now.
    public var pausedSecondsLeft: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let pausedUntil else { return nil }
        let left = pausedUntil.timeIntervalSince(now())
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    public var consecutiveFailures: Int {
        lock.lock(); defer { lock.unlock() }
        return failures
    }

    /// Returns true when this failure starts a pause.
    @discardableResult
    public func record(success: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if success {
            failures = 0
            pausedUntil = nil
            return false
        }
        failures += 1
        guard failures >= Self.failureLimit else { return false }
        pausedUntil = now().addingTimeInterval(Self.pause)
        return true
    }
}

/// One dictation's real-time session, from the start of the recording to the text.
public final class RealtimeDictation: @unchecked Sendable {
    /// Why a dictation does not stream (the upload runs as before).
    public enum Skip: Error, Equatable, Sendable {
        /// Setting off, engine without a real-time model, or no ElevenLabs key.
        case unavailable(RealtimeSTTUnavailable)
        /// Too many failures in a row (`RealtimeBackoff`).
        case paused(secondsLeft: Int)

        public var logDescription: String {
            switch self {
            case .unavailable(let reason): return reason.rawValue
            case .paused(let left): return "paused(\(left)s-left)"
            }
        }
    }

    let session: RealtimeSTTSession
    /// The configuration the session was opened with (its engine and language).
    let resolvedAtStart: ResolvedModeConfig
    let tag: String

    private let lock = NSLock()
    // Guarded by `lock`.
    private var failure: RealtimeSTTError?
    private var final: Task<String, Error>?
    private var stoppedAt: DispatchTime?
    private var cancelled = false

    init(session: RealtimeSTTSession, resolved: ResolvedModeConfig, tag: String) {
        self.session = session
        resolvedAtStart = resolved
        self.tag = tag
        // Nobody shows the text, but the event stream buffers until read: drain it, and note a
        // failure while recording (the session is already closed then; the upload runs at stop).
        let events = session.events
        Task.detached(priority: .utility) { [weak self] in
            for await event in events {
                if case .error(let error) = event { self?.noteFailure(error) }
            }
        }
    }

    // MARK: Start

    /// Whether `resolved` streams, without reading the key or touching the network (cheap; call
    /// it before the clip starts). nil = try; `start` then reads the key.
    public static func skipReason(_ resolved: ResolvedModeConfig, backoff: RealtimeBackoff) -> Skip? {
        guard resolved.realtimeEnabled else { return .unavailable(.disabled) }
        guard resolved.sttProvider == .elevenLabsScribe else { return .unavailable(.engine) }
        if let left = backoff.pausedSecondsLeft { return .paused(secondsLeft: left) }
        return nil
    }

    /// A started session (connecting in the background on the session's own queue; this returns
    /// right away), or why there is none. Reads the ElevenLabs key and the personal dictionary.
    public static func start(resolved: ResolvedModeConfig, backoff: RealtimeBackoff, logTag: String,
                             keys: KeychainStore = .shared, dictionary: DictionaryStore = .shared,
                             configuration: RealtimeSTTSession.Configuration = .default) -> Result<RealtimeDictation, Skip> {
        start(resolved: resolved, backoff: backoff, logTag: logTag) {
            RealtimeSTTSession.make(resolved: $0, keys: keys, dictionary: dictionary, logTag: logTag,
                                    configuration: configuration)
        }
    }

    static func start(resolved: ResolvedModeConfig, backoff: RealtimeBackoff, logTag: String,
                      makeSession: (ResolvedModeConfig) -> Result<RealtimeSTTSession, RealtimeSTTUnavailable>)
        -> Result<RealtimeDictation, Skip> {
        if let skip = skipReason(resolved, backoff: backoff) { return .failure(skip) }
        switch makeSession(resolved) {
        case .failure(let reason):
            return .failure(.unavailable(reason))
        case .success(let session):
            let run = RealtimeDictation(session: session, resolved: resolved, tag: logTag)
            session.start()
            return .success(run)
        }
    }

    // MARK: Recording (any thread)

    /// 16 kHz mono samples in -1...1, exactly what goes into the clip file.
    public func append(samples: [Float]) {
        session.append(samples: samples)
    }

    /// The recording stopped and will be transcribed: the rest of the audio and the final commit
    /// go out now, so the answer usually arrives while the pipeline starts. Safe to call twice.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard final == nil, !cancelled else { return }
        stoppedAt = .now()
        let session = self.session
        final = Task.detached(priority: .userInitiated) { try await session.finish() }
    }

    /// Closes the socket (cancel, discarded clip, mode no longer streaming). Safe to call twice.
    public func cancel() {
        lock.lock()
        cancelled = true
        let final = self.final
        lock.unlock()
        session.cancel()
        final?.cancel()
    }

    public var failedWhileRecording: RealtimeSTTError? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    private func noteFailure(_ error: RealtimeSTTError) {
        lock.lock()
        let first = failure == nil && final == nil && !cancelled
        if failure == nil { failure = error }
        lock.unlock()
        if first {
            DiagLog.log("engine", "id=\(tag) realtime failed while recording \(error.logDescription) → upload at stop")
        }
    }

    // MARK: Stop → text

    /// Why the session cannot stand in for the upload of a request resolved at stop (the keyboard
    /// may change the mode with the stop), or nil when it can.
    static func mismatch(start: ResolvedModeConfig, stop: ResolvedModeConfig) -> String? {
        if !stop.realtimeEnabled { return "disabled" }
        if stop.sttProvider != start.sttProvider { return "engine" }
        if stop.languageCode != start.languageCode { return "language" }
        return nil
    }

    /// The streamed transcript and the milliseconds from stop to it, or nil when the upload must
    /// run (logged with the reason, counted by `backoff`). Throws only `ProviderError.cancelled`.
    func transcript(for resolved: ResolvedModeConfig, backoff: RealtimeBackoff,
                    log: (String) -> Void) async throws -> (text: String, millis: Int)? {
        if let reason = Self.mismatch(start: resolvedAtStart, stop: resolved) {
            cancel()
            log("id=\(tag) path=batch reason=mode-changed(\(reason))")
            return nil
        }
        if let failure = failedWhileRecording {
            noteOutcome(success: false, backoff: backoff, log: log)
            log("id=\(tag) path=batch reason=failed-while-recording \(failure.logDescription)")
            return nil
        }
        stop()
        guard let (final, stoppedAt) = finishing() else { throw ProviderError.cancelled }
        do {
            let text = try await withTaskCancellationHandler {
                try await final.value
            } onCancel: { [self] in
                cancel()
            }
            let millis = RealtimeSTTSession.millis(since: stoppedAt)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                noteOutcome(success: false, backoff: backoff, log: log)
                log("id=\(tag) path=batch reason=empty-realtime-transcript stopToFinalMs=\(millis)")
                return nil
            }
            noteOutcome(success: true, backoff: backoff, log: log)
            let metrics = session.currentMetrics
            log("id=\(tag) path=realtime stopToFinalMs=\(millis) chars=\(text.count) "
                + "connectMs=\(metrics.connectMillis ?? -1) commitMs=\(metrics.finalCommitMillis ?? -1) "
                + "commits=\(metrics.commitsSent) audio=\(String(format: "%.1f", metrics.audioSecondsSent))s")
            return (text, millis)
        } catch {
            let realtimeError = error as? RealtimeSTTError
            if Task.isCancelled || realtimeError?.reason == .cancelled || isCancelled { throw ProviderError.cancelled }
            noteOutcome(success: false, backoff: backoff, log: log)
            log("id=\(tag) path=batch reason=\(realtimeError?.logDescription ?? "error") "
                + "afterMs=\(RealtimeSTTSession.millis(since: stoppedAt))")
            return nil
        }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// The final-commit task started by `stop()` and when it started; nil after `cancel()`.
    private func finishing() -> (Task<String, Error>, DispatchTime)? {
        lock.lock(); defer { lock.unlock() }
        guard let final, !cancelled else { return nil }
        return (final, stoppedAt ?? .now())
    }

    private func noteOutcome(success: Bool, backoff: RealtimeBackoff, log: (String) -> Void) {
        guard backoff.record(success: success) else { return }
        log("realtime failed \(backoff.consecutiveFailures)× in a row → upload only for \(Int(RealtimeBackoff.pause))s")
    }
}

public extension DictationPipeline {
    /// A dictation recorded with `realtime` riding along (nil: the upload, exactly as
    /// `run(audioFile:request:)`). The request is resolved now, with what the stop carried.
    /// Exactly one path produces the text: the streamed transcript when there is one, else
    /// `audioFile`. Writes one `path=realtime|batch` line. Cancelling the task cancels the session.
    func run(audioFile: URL, request: DictationRequest, realtime: RealtimeDictation?,
             backoff: RealtimeBackoff) async throws -> PipelineResult {
        guard let realtime else { return try await run(audioFile: audioFile, request: request) }
        let resolved = resolve(request)
        if let streamed = try await realtime.transcript(for: resolved, backoff: backoff, log: log) {
            if Task.isCancelled { throw ProviderError.cancelled }
            return try await run(transcript: streamed.text, request: request, resolved: resolved,
                                 sttMillis: streamed.millis)
        }
        if Task.isCancelled { throw ProviderError.cancelled }
        return try await run(audioFile: audioFile, request: request, resolved: resolved)
    }
}
