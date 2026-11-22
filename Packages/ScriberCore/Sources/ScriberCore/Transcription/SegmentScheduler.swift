import Foundation
import ScriberShared

/// Retries for one segment.
public struct RetryPolicy: Sendable, Equatable {
    /// Attempts for transient failures (timeouts, connection problems, 5xx).
    public var maxAttempts = 3
    /// Attempts while the engine answers 429 (too many requests / concurrent requests).
    public var maxRateLimitedAttempts = 6
    /// First backoff; doubles each time, with ±25 % jitter.
    public var baseDelay: TimeInterval = 2
    public var maxDelay: TimeInterval = 60

    public init() {}
    public init(maxAttempts: Int, maxRateLimitedAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval) {
        self.maxAttempts = maxAttempts; self.maxRateLimitedAttempts = maxRateLimitedAttempts
        self.baseDelay = baseDelay; self.maxDelay = maxDelay
    }

    func backoff(attempt: Int, jitter: Double = Double.random(in: 0.75...1.25)) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))) * jitter)
    }
}

/// How a segment attempt failed, deciding what happens next.
enum SegmentFailureKind: Equatable {
    case cancelled
    /// Nothing will work until the user fixes something (key, quota, settings): stop the job.
    case fatal(String)
    /// This segment cannot be transcribed as is; others may still work.
    case segment(String)
    /// Worth retrying (timeouts, network, 5xx).
    case transient(String)
    /// 429: slow down, then retry.
    case rateLimited(retryAfter: TimeInterval?, message: String)

    static func classify(_ error: Error) -> SegmentFailureKind {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        if let limited = error as? RateLimitedError {
            if limited.message.lowercased().contains("quota") {
                return .fatal(ProviderError.http(status: 402, message: limited.message).errorDescription ?? "")
            }
            return .rateLimited(retryAfter: limited.retryAfter,
                                message: ProviderError.http(status: 429, message: "").errorDescription ?? "")
        }
        if let custom = error as? CustomSTTError { return .fatal(custom.errorDescription ?? "") }
        guard let provider = error as? ProviderError else {
            return .transient(ProviderError.network("transport").errorDescription ?? "")
        }
        let message = provider.errorDescription ?? ""
        switch provider {
        case .cancelled:
            return .cancelled
        case .missingAPIKey:
            return .fatal(message)
        case .emptyResult:
            return .segment(message)
        case .network(let code):
            if code == ProviderError.audioUnreadableCode { return .segment(message) }
            return .transient(message)
        case .http(let status, let serverMessage):
            let lowered = serverMessage.lowercased()
            if status == 402 || lowered.contains("quota") || lowered.contains("credit balance") { return .fatal(message) }
            switch status {
            case 429: return .rateLimited(retryAfter: nil, message: message)
            case 401, 403, 404: return .fatal(message)
            case 408, 409, 425, 500...599: return .transient(message)
            default: return .segment(message)
            }
        }
    }
}

/// What happened to one segment.
public enum SegmentOutcome: Sendable, Equatable {
    case success(TimedText)
    /// Gave up after retries (or the engine rejected this piece); the message is user-facing.
    case failed(String)
}

/// Bounded-concurrency transcription of segments as they become available.
///
/// - At most `limit` requests run at once. A 429 halves the limit (down to 1) and pauses new
///   attempts for the server's `Retry-After` (or the backoff); after a few successes in a row the
///   limit grows back by one.
/// - Each segment is retried on its own; finished segments are never redone.
/// - A fatal error (bad key, no quota, broken custom-engine settings) stops everything and is
///   reported once; segments not yet finished stay pending for a later resume.
/// - `cancel()` stops in-flight requests promptly (URLSession tasks are cancelled with their Swift task).
public actor SegmentScheduler {
    public typealias Transcribe = @Sendable (SegmentInfo) async throws -> TimedText
    public typealias Deliver = @Sendable (Int, SegmentOutcome) async -> Void

    public enum Completion: Sendable, Equatable {
        case finished
        case fatal(String)
        case cancelled
    }

    private let maxLimit: Int
    private let retry: RetryPolicy
    private let transcribe: Transcribe
    private let deliver: Deliver
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private(set) var limit: Int
    private var queue: [SegmentInfo] = []
    private var running: [Int: Task<Void, Never>] = [:]
    private var inputClosed = false
    private var stopped: Completion?
    private var cooldownUntil: Date?
    private var successStreak = 0
    private var waiters: [CheckedContinuation<Completion, Never>] = []
    /// Highest number of requests that were in flight at once (tests).
    private(set) var peakRunning = 0

    public init(concurrency: Int, retry: RetryPolicy, transcribe: @escaping Transcribe, deliver: @escaping Deliver,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = SegmentScheduler.taskSleep) {
        maxLimit = max(1, concurrency)
        limit = max(1, concurrency)
        self.retry = retry
        self.transcribe = transcribe
        self.deliver = deliver
        self.sleep = sleep
    }

    public static let taskSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    public func enqueue(_ segment: SegmentInfo) {
        guard stopped == nil else { return }
        queue.append(segment)
        pump()
    }

    /// No more segments will be enqueued.
    public func closeInput() {
        inputClosed = true
        checkDone()
    }

    public func cancel() {
        stop(.cancelled)
    }

    /// Waits until every enqueued segment has an outcome (after `closeInput()`), a fatal error, or
    /// `cancel()`.
    public func waitUntilDone() async -> Completion {
        if let result = doneResult() { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: Internals

    private func pump() {
        while stopped == nil, running.count < limit, !queue.isEmpty {
            let segment = queue.removeFirst()
            running[segment.index] = Task { [weak self] in
                guard let self else { return }
                let outcome = await self.attempt(segment)
                await self.finished(segment, outcome)
            }
            peakRunning = max(peakRunning, running.count)
        }
    }

    private enum AttemptResult {
        case outcome(SegmentOutcome)
        case fatal(String)
        case cancelled
    }

    private func attempt(_ segment: SegmentInfo) async -> AttemptResult {
        var failures = 0
        var rateLimited = 0
        while true {
            if let until = cooldownUntil, until > Date() {
                do { try await sleep(until.timeIntervalSinceNow) } catch { return .cancelled }
            }
            if Task.isCancelled || stopped != nil { return .cancelled }
            do {
                let text = try await transcribe(segment)
                if Task.isCancelled { return .cancelled }
                noteSuccess()
                return .outcome(.success(text))
            } catch {
                if Task.isCancelled { return .cancelled }
                switch SegmentFailureKind.classify(error) {
                case .cancelled:
                    return .cancelled
                case .fatal(let message):
                    return .fatal(message)
                case .segment(let message):
                    DiagLog.log("transcribe", "segment \(segment.index) rejected: \(Self.logCode(error))")
                    return .outcome(.failed(message))
                case .transient(let message):
                    failures += 1
                    DiagLog.log("transcribe", "segment \(segment.index) attempt \(failures) failed: \(Self.logCode(error))")
                    guard failures < retry.maxAttempts else { return .outcome(.failed(message)) }
                    do { try await sleep(retry.backoff(attempt: failures)) } catch { return .cancelled }
                case .rateLimited(let retryAfter, let message):
                    rateLimited += 1
                    let wait = max(retryAfter ?? 0, retry.backoff(attempt: rateLimited))
                    throttle(for: wait)
                    DiagLog.log("transcribe", "segment \(segment.index) 429 (#\(rateLimited)) limit=\(limit) wait=\(String(format: "%.1f", wait))s")
                    guard rateLimited < retry.maxRateLimitedAttempts else { return .outcome(.failed(message)) }
                    do { try await sleep(wait) } catch { return .cancelled }
                }
            }
        }
    }

    private func throttle(for seconds: TimeInterval) {
        limit = max(1, limit / 2)
        successStreak = 0
        let until = Date().addingTimeInterval(seconds)
        if cooldownUntil.map({ $0 < until }) ?? true { cooldownUntil = until }
    }

    private func noteSuccess() {
        successStreak += 1
        if limit < maxLimit, successStreak >= 3 {
            limit += 1
            successStreak = 0
        }
    }

    private func finished(_ segment: SegmentInfo, _ result: AttemptResult) async {
        switch result {
        case .outcome(let outcome):
            if stopped == nil { await deliver(segment.index, outcome) }
        case .fatal(let message):
            stop(.fatal(message))
        case .cancelled:
            break
        }
        running[segment.index] = nil
        pump()
        checkDone()
    }

    private func stop(_ completion: Completion) {
        guard stopped == nil else { return }
        stopped = completion
        queue.removeAll()
        for task in running.values { task.cancel() }
        checkDone()
    }

    private func doneResult() -> Completion? {
        if let stopped {
            // Wait for in-flight tasks to unwind so their files are no longer in use.
            return running.isEmpty ? stopped : nil
        }
        if inputClosed, queue.isEmpty, running.isEmpty { return .finished }
        return nil
    }

    private func checkDone() {
        guard let result = doneResult() else { return }
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume(returning: result) }
    }

    /// Error type and status only (no server text, which could echo user content).
    static func logCode(_ error: Error) -> String {
        switch error {
        case let provider as ProviderError:
            switch provider {
            case .http(let status, _): return "http \(status)"
            case .network(let code): return "network \(code)"
            case .missingAPIKey(let kind): return "missing key \(kind.rawValue)"
            case .emptyResult: return "empty"
            case .cancelled: return "cancelled"
            }
        case is RateLimitedError: return "http 429"
        case let custom as CustomSTTError: return "custom \(custom)"
        default: return String(describing: type(of: error))
        }
    }
}
