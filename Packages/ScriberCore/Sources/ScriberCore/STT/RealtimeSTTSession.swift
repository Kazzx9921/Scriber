import Foundation
import ScriberShared

// Real-time transcription session (ElevenLabs Scribe v3 Live). Foundation only, platform-neutral:
// the Mac app shows its text while speaking (docs/PRD-macOS版.md); the iOS app uses it through
// `RealtimeDictation` to have the text ready sooner, showing nothing (docs/PRD.md §11).
//
// Lifecycle: start() connects in the background → append() any number of 16 kHz chunks from any
// thread (buffered until the session has started, bounded) → events stream partial / committed text
// → finish() commits what is left and returns the whole transcript, or throws if the session
// failed or the final commit did not arrive in time; the caller then falls back to the batch path
// on the recorded file. cancel() closes the socket. Every step is logged to DiagLog under "rt"
// (timings, counts, close codes, error types — never transcript text or the key).

/// What a session reports while it runs.
public enum RealtimeSTTEvent: Equatable, Sendable {
    /// `session_started` arrived; audio is flowing.
    case started
    /// Interim text of the segment in progress (raw, as recognized). Replaces the previous partial.
    case partial(String)
    /// Final text of one segment (raw). The partial starts over.
    case committed(String)
    /// The session failed and is closed. `finish()` throws the same error.
    case error(RealtimeSTTError)
    /// The server closed the socket (WebSocket close code, if any).
    case closed(code: Int?)
}

public struct RealtimeSTTError: Error, LocalizedError, Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// No `session_started` within the connect timeout.
        case connectTimeout = "connect-timeout"
        /// The connection could not be made or the upgrade was refused.
        case handshake
        /// The server sent an error event (`serverType`).
        case server
        /// The socket closed before the final transcript.
        case closed
        /// A send or receive failed after the session started.
        case transport
        /// Sends stopped completing: more than the allowed audio is waiting to go out.
        case stalled
        /// Too much audio buffered while still connecting.
        case overflow
        /// The final commit was not answered in time.
        case commitTimeout = "commit-timeout"
        case cancelled
    }

    public var reason: Reason
    /// Server `message_type` for `.server`, e.g. "auth_error".
    public var serverType: String?
    public var closeCode: Int?
    public var httpStatus: Int?
    /// Short transport code for `.handshake` / `.transport` (see `ProviderHTTP.mapTransportError`).
    public var detail: String?

    public init(_ reason: Reason, serverType: String? = nil, closeCode: Int? = nil,
                httpStatus: Int? = nil, detail: String? = nil) {
        self.reason = reason; self.serverType = serverType; self.closeCode = closeCode
        self.httpStatus = httpStatus; self.detail = detail
    }

    /// The same error in the vocabulary of the batch providers (zh-Hant messages, HUD labels).
    public var providerError: ProviderError {
        switch reason {
        case .connectTimeout: return .network(ProviderError.realtimeConnectTimeoutCode)
        case .commitTimeout: return .network(ProviderError.realtimeCommitTimeoutCode)
        case .server: return RealtimeSTTWire.providerError(forServerError: serverType ?? "error", message: "")
        case .handshake:
            if let httpStatus, !(200..<300).contains(httpStatus), httpStatus != 101 {
                return .http(status: httpStatus, message: "realtime-handshake")
            }
            return .network(detail ?? ProviderError.realtimeClosedCode)
        case .closed, .transport: return .network(ProviderError.realtimeClosedCode)
        case .stalled, .overflow: return .network(ProviderError.realtimeStalledCode)
        case .cancelled: return .cancelled
        }
    }

    public var errorDescription: String? { providerError.errorDescription }

    /// Content-free one-liner for DiagLog.
    public var logDescription: String {
        var parts = ["reason=\(reason.rawValue)"]
        if let serverType { parts.append("type=\(serverType)") }
        if let closeCode { parts.append("close=\(closeCode)") }
        if let httpStatus { parts.append("http=\(httpStatus)") }
        if let detail { parts.append("detail=\(detail)") }
        return parts.joined(separator: " ")
    }
}

/// Why real-time is not used for a dictation (logged; the batch path runs as before).
public enum RealtimeSTTUnavailable: String, Error, Sendable {
    case disabled
    /// The selected engine has no real-time mode.
    case engine
    case missingKey = "missing-key"
}

public final class RealtimeSTTSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// From start() to `session_started` (live: ~0.3 s).
        public var connectTimeout: TimeInterval = 5
        /// From the final commit leaving the device to its `committed_transcript` (live: ~0.23 s,
        /// ~1.3 s after a burst of 10 s of audio).
        public var commitTimeout: TimeInterval = 3
        /// Cap on `finish()` as a whole, including audio still waiting to be sent.
        public var finishTimeout: TimeInterval = 8
        /// Chunk length (documented range 0.1–1 s).
        public var chunkSeconds: Double = 0.2
        /// Audio held while connecting; beyond this the session fails (the clip is still recorded).
        public var maxBufferedSeconds: Double = 12
        /// A send not completed after this long means the connection is stalled (back-pressure).
        public var maxSendDelay: TimeInterval = 4
        /// Memory bound on audio handed to the socket but not yet sent, whatever its age.
        public var maxInFlightSeconds: Double = 30
        var planner = RealtimeCommitPlanner()

        public init() {}
        public static let `default` = Configuration()
    }

    /// Timings for the log and for `PipelineResult`.
    public struct Metrics: Sendable, Equatable {
        public var connectMillis: Int?
        /// From the first audio sent to the first non-empty partial.
        public var firstPartialMillis: Int?
        /// From the final commit to its answer.
        public var finalCommitMillis: Int?
        /// From `finish()` to the final transcript.
        public var finishMillis: Int?
        public var chunksSent = 0
        public var audioSecondsSent: Double = 0
        public var commitsSent = 0
        public var autoCommits = 0
    }

    public let events: AsyncStream<RealtimeSTTEvent>
    private let continuation: AsyncStream<RealtimeSTTEvent>.Continuation
    private let request: URLRequest
    private let apiKey: String
    private let configuration: Configuration
    private let makeTransport: @Sendable () -> RealtimeTransport
    private let tag: String
    private let queue = DispatchQueue(label: "com.geekaz.Scriber.realtime-stt", qos: .userInitiated)
    private let chunkBytes: Int

    // MARK: Queue-confined state

    private enum Phase: String { case idle, connecting, streaming, done }
    private var phase = Phase.idle
    private var transport: RealtimeTransport?
    private var pending = Data()       // less than one chunk, not yet framed
    private var backlog: [Data] = []   // framed chunks waiting for session_started
    private var backlogBytes = 0
    private var inFlightBytes = 0
    private var inFlightSince: [DispatchTime] = [] // send time of each message not yet completed, oldest first
    private var library: [String]      // keyterm library, attached to the first chunk only
    private var firstChunkSent = false
    private var planner: RealtimeCommitPlanner
    private var transcript = RealtimeTranscript()
    private var outstandingCommits = 0
    private var finishRequested = false
    private var finalStepsDone = false
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var outcome: Result<String, RealtimeSTTError>?
    private var timers: [DispatchWorkItem] = []
    private var loggedUnknown = Set<String>()
    private var metrics = Metrics()
    private var startedAt: DispatchTime?
    private var firstAudioAt: DispatchTime?
    private var finishAt: DispatchTime?
    private var finalCommitAt: DispatchTime?

    /// `logTag`: a short request id for the log lines.
    public convenience init(apiKey: String, parameters: RealtimeSTTWire.Parameters,
                            configuration: Configuration = .default, logTag: String = "-") {
        self.init(apiKey: apiKey, parameters: parameters, configuration: configuration, logTag: logTag,
                  endpoint: RealtimeSTTWire.endpoint, makeTransport: { URLSessionRealtimeTransport() })
    }

    init(apiKey: String, parameters: RealtimeSTTWire.Parameters, configuration: Configuration, logTag: String,
         endpoint: URL, makeTransport: @escaping @Sendable () -> RealtimeTransport) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.makeTransport = makeTransport
        self.tag = logTag
        request = RealtimeSTTWire.request(for: parameters, apiKey: apiKey, endpoint: endpoint)
        let split = RealtimeSTTWire.splitKeyterms(parameters.keyterms)
        library = split.library
        planner = configuration.planner
        chunkBytes = max(2, Int(configuration.chunkSeconds * Double(RealtimeSTTWire.bytesPerSecond)) & ~1)
        (events, continuation) = AsyncStream.makeStream(of: RealtimeSTTEvent.self, bufferingPolicy: .unbounded)
        DiagLog.log("rt", "[\(logTag)] new session model=\(RealtimeSTTWire.modelID) lang=\(parameters.languageCode ?? "auto") "
                    + "secondary=\(parameters.secondaryLanguages.joined(separator: ",")) keyterms=\(split.query.count) "
                    + "library=\(split.library.count) noVerbatim=\(parameters.noVerbatim)")
    }

    deinit {
        transport?.close()
        continuation.finish()
    }

    public var currentMetrics: Metrics { queue.sync { metrics } }

    // MARK: Public API (any thread)

    /// Starts connecting. Audio appended before the session is up is kept (bounded) and sent then.
    public func start() {
        queue.async { [self] in
            guard phase == .idle, outcome == nil else { return }
            phase = .connecting
            startedAt = .now()
            let transport = makeTransport()
            self.transport = transport
            transport.open(request) { [weak self] event in
                guard let self else { return }
                self.queue.async { self.handle(event) }
            }
            schedule(after: configuration.connectTimeout) { [self] in
                if phase == .connecting { fail(RealtimeSTTError(.connectTimeout)) }
            }
        }
    }

    /// 16 kHz mono samples in -1...1 (what `StreamingResampler` produces).
    public func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        append(pcm16: PCM16.littleEndianData(from: samples))
    }

    /// 16-bit little-endian mono PCM at 16 kHz.
    public func append(pcm16 data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard outcome == nil, !finishRequested, phase == .connecting || phase == .streaming else { return }
            pending.append(data)
            while pending.count >= chunkBytes, outcome == nil {
                let chunk = pending.prefix(chunkBytes)
                pending = Data(pending.dropFirst(chunkBytes))
                frame(Data(chunk))
            }
        }
    }

    /// Commits the rest and returns the full transcript (raw, as recognized). Throws
    /// `RealtimeSTTError` if the session failed, was cancelled, or the final commit did not arrive
    /// within the configured timeouts. Cancelling the calling task cancels the session.
    public func finish() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                queue.async { [self] in beginFinish(cont) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Closes the socket and drops everything. `finish()` throws `.cancelled`.
    public func cancel() {
        queue.async { [self] in
            guard outcome == nil else { return }
            log("cancelled phase=\(phase.rawValue)")
            complete(.failure(RealtimeSTTError(.cancelled)), emitError: false)
        }
    }

    // MARK: Audio (queue)

    private func frame(_ chunk: Data) {
        switch phase {
        case .connecting:
            backlog.append(chunk)
            backlogBytes += chunk.count
            if Double(backlogBytes) / Double(RealtimeSTTWire.bytesPerSecond) > configuration.maxBufferedSeconds {
                fail(RealtimeSTTError(.overflow))
            }
        case .streaming:
            sendChunk(chunk, planCommits: true)
        case .idle, .done:
            break
        }
    }

    private func sendChunk(_ chunk: Data, planCommits: Bool) {
        guard let transport, outcome == nil else { return }
        let message: String
        if !firstChunkSent, !library.isEmpty {
            message = RealtimeSTTWire.audioChunk(chunk, library: library)
        } else {
            message = RealtimeSTTWire.audioChunk(chunk)
        }
        firstChunkSent = true
        if firstAudioAt == nil { firstAudioAt = .now() }
        metrics.chunksSent += 1
        metrics.audioSecondsSent += Double(chunk.count) / Double(RealtimeSTTWire.bytesPerSecond)
        let bytes = chunk.count
        guard checkBackPressure(adding: bytes) else { return }
        transport.send(message) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.inFlightBytes -= bytes
                if !self.inFlightSince.isEmpty { self.inFlightSince.removeFirst() }
                if let error, self.outcome == nil {
                    self.fail(RealtimeSTTError(.transport, detail: Self.transportCode(error)))
                }
            }
        }
        let level = Self.level(ofPCM16: chunk)
        if planner.didSend(bytes: bytes, level: level), planCommits {
            log(String(format: "periodic commit at %.1fs of uncommitted audio level=%.2f",
                       planner.uncommittedSeconds, level))
            sendCommit(final: false)
        }
    }

    /// Never buffers unbounded audio behind a stalled socket: fails the session (the clip is still
    /// recorded, so the batch path takes over) when the oldest send has waited too long or too much
    /// audio is queued. A burst (the backlog after connecting) is fine as long as it drains.
    private func checkBackPressure(adding bytes: Int) -> Bool {
        if let oldest = inFlightSince.first,
           Double(DispatchTime.now().uptimeNanoseconds &- oldest.uptimeNanoseconds) / 1e9 > configuration.maxSendDelay {
            fail(RealtimeSTTError(.stalled, detail: "send-delay"))
            return false
        }
        if Double(inFlightBytes + bytes) / Double(RealtimeSTTWire.bytesPerSecond) > configuration.maxInFlightSeconds {
            fail(RealtimeSTTError(.stalled, detail: "in-flight"))
            return false
        }
        inFlightBytes += bytes
        inFlightSince.append(.now())
        return true
    }

    private func sendCommit(final: Bool) {
        guard let transport, outcome == nil else { return }
        planner.didCommit()
        outstandingCommits += 1
        metrics.commitsSent += 1
        if final { finalCommitAt = .now() }
        guard checkBackPressure(adding: 0) else { return }
        transport.send(RealtimeSTTWire.commitMessage) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if !self.inFlightSince.isEmpty { self.inFlightSince.removeFirst() }
                if let error, self.outcome == nil {
                    self.fail(RealtimeSTTError(.transport, detail: Self.transportCode(error)))
                    return
                }
                // The commit timeout runs once the commit is actually on its way.
                if final, self.outcome == nil {
                    self.schedule(after: self.configuration.commitTimeout) { [self] in
                        if self.outcome == nil { self.fail(RealtimeSTTError(.commitTimeout)) }
                    }
                }
            }
        }
    }

    // MARK: Finish (queue)

    private func beginFinish(_ cont: CheckedContinuation<String, Error>) {
        if let outcome {
            cont.resume(with: outcome.mapError { $0 as Error })
            return
        }
        guard finishContinuation == nil else {
            cont.resume(throwing: RealtimeSTTError(.cancelled, detail: "finish-called-twice"))
            return
        }
        finishContinuation = cont
        finishRequested = true
        finishAt = .now()
        schedule(after: configuration.finishTimeout) { [self] in
            if outcome == nil { fail(RealtimeSTTError(.commitTimeout, detail: "finish-cap")) }
        }
        switch phase {
        case .streaming: performFinalSteps()
        case .connecting: break // session_started runs the final steps; the connect timeout bounds it
        case .idle: fail(RealtimeSTTError(.closed, detail: "never-started"))
        case .done: break
        }
    }

    private func performFinalSteps() {
        guard !finalStepsDone, outcome == nil else { return }
        finalStepsDone = true
        if !pending.isEmpty {
            // The last partial chunk; no periodic commit now, the final one follows.
            let tail = pending
            pending = Data()
            sendChunk(tail, planCommits: false)
        }
        switch planner.finalAction(partialIsEmpty: transcript.partial.isEmpty) {
        case .none:
            log("final: nothing uncommitted with speech, no commit needed")
        case .commit:
            sendCommit(final: true)
        case .padThenCommit(let bytes):
            sendChunk(Data(count: bytes), planCommits: false)
            sendCommit(final: true)
        }
        completeIfDone()
    }

    private func completeIfDone() {
        guard finishRequested, finalStepsDone, outstandingCommits == 0, outcome == nil else { return }
        if let finalCommitAt { metrics.finalCommitMillis = Self.millis(since: finalCommitAt) }
        if let finishAt { metrics.finishMillis = Self.millis(since: finishAt) }
        let text = transcript.finalText
        log("final ok finishMs=\(metrics.finishMillis ?? -1) commitMs=\(metrics.finalCommitMillis ?? -1) "
            + "segments=\(transcript.segments.count) commits=\(transcript.commitCount) auto=\(metrics.autoCommits) "
            + "chars=\(text.count) chunks=\(metrics.chunksSent) audio=\(String(format: "%.1f", metrics.audioSecondsSent))s")
        complete(.success(text), emitError: false)
    }

    // MARK: Transport events (queue)

    private func handle(_ event: RealtimeTransportEvent) {
        switch event {
        case .text(let text):
            handle(RealtimeSTTWire.decode(text))
        case .binary(let count):
            logOnce("binary", "unexpected binary frame bytes=\(count) (ignored)")
        case .closed(let code, let reason):
            let reasonText = reason.map { RealtimeSTTWire.logSafe($0, secret: apiKey) } ?? ""
            log("socket closed code=\(code.map(String.init) ?? "-") reason=\(reasonText.isEmpty ? "-" : reasonText) "
                + "phase=\(phase.rawValue)")
            guard outcome == nil else { return }
            continuation.yield(.closed(code: code))
            fail(RealtimeSTTError(phase == .connecting ? .handshake : .closed, closeCode: code))
        case .failed(let code, let status):
            log("socket failed detail=\(code) http=\(status.map(String.init) ?? "-") phase=\(phase.rawValue)")
            guard outcome == nil else { return }
            fail(RealtimeSTTError(phase == .connecting ? .handshake : .transport, httpStatus: status, detail: code))
        }
    }

    private func handle(_ event: RealtimeServerEvent) {
        guard outcome == nil else { return }
        switch event {
        case .sessionStarted(let id):
            guard phase == .connecting else { return }
            phase = .streaming
            if let startedAt { metrics.connectMillis = Self.millis(since: startedAt) }
            let buffered = Double(backlogBytes) / Double(RealtimeSTTWire.bytesPerSecond)
            log("connected ms=\(metrics.connectMillis ?? -1) session=\(id.map { String($0.prefix(8)) } ?? "-") "
                + "buffered=\(String(format: "%.1f", buffered))s")
            continuation.yield(.started)
            let queued = backlog
            backlog = []
            backlogBytes = 0
            for chunk in queued where outcome == nil { sendChunk(chunk, planCommits: true) }
            if finishRequested { performFinalSteps() }
        case .partial(let text):
            transcript.applyPartial(text)
            if metrics.firstPartialMillis == nil, !transcript.partial.isEmpty, let firstAudioAt {
                metrics.firstPartialMillis = Self.millis(since: firstAudioAt)
                log("first partial ms=\(metrics.firstPartialMillis ?? -1) after first audio")
            }
            continuation.yield(.partial(text))
        case .committed(let text):
            if outstandingCommits > 0 {
                outstandingCommits -= 1
            } else {
                metrics.autoCommits += 1
                log("server committed without a commit from us (auto-commit)")
            }
            transcript.applyCommitted(text)
            continuation.yield(.committed(text))
            completeIfDone()
        case .serverError(let type, let message):
            log("server error type=\(type) msg=\(RealtimeSTTWire.logSafe(message, secret: apiKey))")
            fail(RealtimeSTTError(.server, serverType: type))
        case .warning:
            logOnce("warning", "server warning (ignored)")
        case .ignored(let type):
            logOnce(type, "ignored event type=\(type)")
        case .unknown(let type):
            logOnce(type, "unknown event type=\(type) (ignored)")
        }
    }

    // MARK: Completion (queue)

    private func fail(_ error: RealtimeSTTError) {
        guard outcome == nil else { return }
        log("failed \(error.logDescription) phase=\(phase.rawValue) audio=\(String(format: "%.1f", metrics.audioSecondsSent))s "
            + "commits=\(metrics.commitsSent) answered=\(transcript.commitCount)")
        complete(.failure(error), emitError: true)
    }

    private func complete(_ result: Result<String, RealtimeSTTError>, emitError: Bool) {
        guard outcome == nil else { return }
        outcome = result
        phase = .done
        for timer in timers { timer.cancel() }
        timers.removeAll()
        backlog.removeAll()
        pending = Data()
        if emitError, case .failure(let error) = result { continuation.yield(.error(error)) }
        continuation.finish()
        transport?.close()
        transport = nil
        if let cont = finishContinuation {
            finishContinuation = nil
            cont.resume(with: result.mapError { $0 as Error })
        }
    }

    private func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        timers.append(item)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: Helpers

    private func log(_ message: String) {
        DiagLog.log("rt", "[\(tag)] \(message)")
    }

    private func logOnce(_ key: String, _ message: String) {
        guard loggedUnknown.insert(key).inserted else { return }
        log(message)
    }

    static func millis(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }

    static func transportCode(_ error: Error) -> String {
        switch ProviderHTTP.mapTransportError(error) {
        case .network(let code): return code
        case .cancelled: return "cancelled"
        default: return "transport"
        }
    }

    /// `PCMLevel` of a 16-bit LE chunk.
    static func level(ofPCM16 data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let s = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                sum += s * s
            }
        }
        return PCMLevel.level(rms: (sum / Float(count)).squareRoot())
    }
}

// MARK: - Availability

extension RealtimeSTTSession {
    /// The session for the next dictation, if real-time applies: the setting is on, the selected
    /// engine is ElevenLabs Scribe, and its key exists. Otherwise the reason (the batch path runs).
    public static func make(settings: AppSettings = .shared, keys: KeychainStore = .shared,
                            dictionary: DictionaryStore = .shared, logTag: String = "-",
                            configuration: Configuration = .default) -> Result<RealtimeSTTSession, RealtimeSTTUnavailable> {
        guard settings.realtimeEnabled else { return .failure(.disabled) }
        guard settings.sttProvider == .elevenLabsScribe else { return .failure(.engine) }
        guard let key = try? STTFactory.requireKey(.elevenLabs, keys: keys) else { return .failure(.missingKey) }
        let parameters = RealtimeSTTWire.Parameters(
            languageCode: PipelineConfig(settings: settings).languageCode,
            keyterms: DictationPipeline.keyterms(from: dictionary.snapshot()))
        return .success(RealtimeSTTSession(apiKey: key, parameters: parameters, configuration: configuration,
                                           logTag: logTag))
    }

    /// Same, for a mode resolved by `ModeResolver` (the mode's engine, language and 即時顯示 setting).
    public static func make(resolved: ResolvedModeConfig, keys: KeychainStore = .shared,
                            dictionary: DictionaryStore = .shared, logTag: String = "-",
                            configuration: Configuration = .default) -> Result<RealtimeSTTSession, RealtimeSTTUnavailable> {
        guard resolved.realtimeEnabled else { return .failure(.disabled) }
        guard resolved.sttProvider == .elevenLabsScribe else { return .failure(.engine) }
        guard let key = try? STTFactory.requireKey(.elevenLabs, keys: keys) else { return .failure(.missingKey) }
        let parameters = RealtimeSTTWire.Parameters(
            languageCode: resolved.languageCode,
            keyterms: DictationPipeline.keyterms(from: dictionary.snapshot()))
        return .success(RealtimeSTTSession(apiKey: key, parameters: parameters, configuration: configuration,
                                           logTag: logTag))
    }
}

// MARK: - Transport

enum RealtimeTransportEvent: Sendable {
    case text(String)
    case binary(Int)
    /// The WebSocket closed (close code if the peer sent one).
    case closed(code: Int?, reason: String?)
    /// The connection failed; `code` is a `ProviderHTTP` transport code, `httpStatus` the upgrade
    /// response status if there was one.
    case failed(code: String, httpStatus: Int?)
}

/// The socket under a session; a fake in tests.
protocol RealtimeTransport: AnyObject, Sendable {
    /// `onEvent` may be called on any thread; nothing is delivered after `close()`.
    func open(_ request: URLRequest, onEvent: @escaping @Sendable (RealtimeTransportEvent) -> Void)
    /// Completion on any thread, nil error when the message was handed to the network.
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    /// Normal closure (1000). Safe to call more than once.
    func close()
}

/// `URLSessionWebSocketTask` with its own session: the shared provider session's 420 s resource
/// timeout would cut a 15-minute dictation, and a delegate is needed for close codes.
final class URLSessionRealtimeTransport: NSObject, RealtimeTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var onEvent: (@Sendable (RealtimeTransportEvent) -> Void)?
    private var ended = false

    func open(_ request: URLRequest, onEvent: @escaping @Sendable (RealtimeTransportEvent) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        // The session retains its delegate until invalidated (end()).
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        lock.lock()
        self.session = session
        self.task = task
        self.onEvent = onEvent
        lock.unlock()
        task.resume()
        receive(task)
    }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        let task = ended ? nil : self.task
        lock.unlock()
        guard let task else {
            completion(URLError(.cancelled))
            return
        }
        task.send(.string(text)) { error in completion(error) }
    }

    func close() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        end()
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.emit(.text(text))
                self.receive(task)
            case .success(.data(let data)):
                self.emit(.binary(data.count))
                self.receive(task)
            case .success:
                self.receive(task)
            case .failure(let error):
                // The close code is already set when the peer closed (live: receive fails with
                // POSIX 57 and closeCode 1000/1008 at the same moment as didClose).
                if task.closeCode != .invalid {
                    let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) }
                    self.finish(.closed(code: task.closeCode.rawValue, reason: reason))
                } else {
                    let status = (task.response as? HTTPURLResponse)?.statusCode
                    self.finish(.failed(code: RealtimeSTTSession.transportCode(error), httpStatus: status))
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.closed(code: closeCode.rawValue, reason: reason.map { String(decoding: $0, as: UTF8.self) }))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        finish(.failed(code: RealtimeSTTSession.transportCode(error), httpStatus: status))
    }

    private func emit(_ event: RealtimeTransportEvent) {
        lock.lock()
        let handler = ended ? nil : onEvent
        lock.unlock()
        handler?(event)
    }

    /// Delivers the terminal event once, then tears down.
    private func finish(_ event: RealtimeTransportEvent) {
        emit(event)
        end()
    }

    private func end() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        onEvent = nil
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
    }
}
