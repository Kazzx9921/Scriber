import Accelerate
import Foundation
import Observation
import ScriberShared

// MARK: - Seams

/// 16 kHz mono float audio, chunk by chunk. `read()` is called from one background task.
public protocol PCMSource: AnyObject, Sendable {
    /// The next chunk, nil at the end. Throws `TranscriptionError` for unreadable input.
    func read() throws -> [Float]?
}

/// Writes one segment file (AAC .m4a normally, WAV as fallback).
public protocol SegmentAudioWriter: AnyObject {
    var url: URL { get }
    func append(_ samples: ArraySlice<Float>) throws
    /// Closes the file and returns its size in bytes.
    func finish() throws -> Int
    func discard()
}

/// What is known about a file before decoding it.
public struct SourceProbe: Sendable, Equatable {
    public var duration: TimeInterval?
    public var hasVideo: Bool
    public init(duration: TimeInterval?, hasVideo: Bool = false) { self.duration = duration; self.hasVideo = hasVideo }
}

/// Everything a job needs from the outside world, injectable for tests.
public struct TranscriptionEnvironment: Sendable {
    /// Folder holding one sub-folder per job (segment audio, results, manifest).
    public var workRoot: URL
    public var store: TranscriptStore
    public var policy: SegmentationPolicy
    public var retry: RetryPolicy
    /// Requests in flight at once (lowered automatically on 429).
    public var concurrency: Int
    public var makeTranscriber: @Sendable (STTProviderKind) throws -> any FileTranscriber
    public var probe: @Sendable (URL) async throws -> SourceProbe
    /// Opens `url` decoding from `startSeconds`.
    public var openSource: @Sendable (URL, TimeInterval) async throws -> any PCMSource
    /// A writer for a segment; the URL has no extension (the writer adds .m4a or .wav).
    public var makeWriter: @Sendable (URL) throws -> any SegmentAudioWriter
    public var keyterms: @Sendable () -> [String]
    public var postProcessor: @Sendable (TranscriptLanguage) -> TranscriptPostProcessor
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(workRoot: URL, store: TranscriptStore, policy: SegmentationPolicy = .standard, retry: RetryPolicy = RetryPolicy(),
                concurrency: Int = 3,
                makeTranscriber: @escaping @Sendable (STTProviderKind) throws -> any FileTranscriber,
                probe: @escaping @Sendable (URL) async throws -> SourceProbe,
                openSource: @escaping @Sendable (URL, TimeInterval) async throws -> any PCMSource,
                makeWriter: @escaping @Sendable (URL) throws -> any SegmentAudioWriter,
                keyterms: @escaping @Sendable () -> [String],
                postProcessor: @escaping @Sendable (TranscriptLanguage) -> TranscriptPostProcessor,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = SegmentScheduler.taskSleep) {
        self.workRoot = workRoot; self.store = store; self.policy = policy; self.retry = retry
        self.concurrency = concurrency; self.makeTranscriber = makeTranscriber; self.probe = probe
        self.openSource = openSource; self.makeWriter = makeWriter; self.keyterms = keyterms
        self.postProcessor = postProcessor; self.sleep = sleep
    }

    public static var defaultWorkRoot: URL {
        AppGroup.containerURL.appendingPathComponent("TranscriptionWork", isDirectory: true)
    }

    /// Dictionary terms for the engines (same as dictation).
    public static let dictionaryKeyterms: @Sendable () -> [String] = {
        DictationPipeline.keyterms(from: DictionaryStore.shared.snapshot())
    }
}

/// 16-bit WAV segment writer (fallback when AAC is unavailable, and for tests).
public final class WAVSegmentWriter: SegmentAudioWriter {
    private let writer: WAVFileWriter
    public var url: URL { writer.url }

    public init(baseURL: URL, sampleRate: Int = 16_000) throws {
        writer = try WAVFileWriter(url: baseURL.deletingPathExtension().appendingPathExtension("wav"), sampleRate: sampleRate)
    }

    public func append(_ samples: ArraySlice<Float>) throws { try writer.append(Array(samples)) }

    public func finish() throws -> Int {
        try writer.finish()
        return 44 + writer.frameCount * 2
    }

    public func discard() {
        try? writer.finish()
        try? FileManager.default.removeItem(at: writer.url)
    }
}

// MARK: - Manifest

/// A job's durable state (`manifest.json` in its folder). Lets an interrupted job (app quit,
/// iOS suspension) continue without redoing finished segments, and failed segments be retried later.
struct JobManifest: Codable, Equatable {
    enum State: String, Codable { case active, paused, failed, done }

    var id: UUID
    var title: String
    var sourceExtension: String
    var sourcePath: String?
    var sourceBookmark: Data?
    var created: Date
    var engine: STTProviderKind
    var options: TranscriptionOptions
    var duration: TimeInterval?
    var singleRequest: Bool?
    var speakersUnavailable = false
    var plannedSegments: Int?
    var segments: [SegmentInfo] = []
    var preparationComplete = false
    var completed: Set<Int> = []
    var failures: [Int: String] = [:]
    var transcriptID: UUID?
    var state: State = .active
    var fatalMessage: String?
    var fatalKind: TranscriptionJob.FailureKind?
}

// MARK: - Job

/// One file being transcribed. Observable from SwiftUI; all state changes happen on the main actor.
///
/// Flow: probe → (decode → 16 kHz mono → quiet-point segments → AAC files) runs alongside
/// (bounded-concurrency transcription with retry) → in-order assembly with post-processing →
/// saved to `TranscriptStore`. Finished segments are on disk, so pause/resume and retrying failed
/// segments never redo work.
@MainActor
@Observable
public final class TranscriptionJob: Identifiable {
    public enum Phase: Equatable, Sendable {
        /// Queued behind another file.
        case waiting
        /// Reading the file (nothing transcribed yet).
        case preparing
        /// Segments are being transcribed (preparation may still be running).
        case transcribing
        /// Assembling and saving.
        case finishing
        /// Saved. `failedSegments` may be non-empty.
        case done
        /// Stopped without losing work: app quit or iOS background time ran out.
        case paused
        /// Stopped by a problem the user must fix (key, quota, unreadable file).
        case failed(String)
        case cancelled
    }

    /// What a `.failed` job needs before it can work.
    public enum FailureKind: String, Codable, Sendable {
        /// The file itself (unreadable, no audio, DRM, gone): retrying will not help.
        case file
        /// A key, quota or engine setting: fix it in Settings, then retry.
        case settings
        /// Anything else (network down for good, disk full): retry later.
        case other
    }

    public struct FailedSegment: Equatable, Sendable, Identifiable {
        public var index: Int
        public var start: TimeInterval
        public var end: TimeInterval
        public var message: String
        public var id: Int { index }
    }

    public nonisolated let id: UUID
    /// When the file was added.
    public let createdAt: Date
    public private(set) var title: String
    public let sourceExtension: String
    public let engine: STTProviderKind
    public let options: TranscriptionOptions
    public private(set) var phase: Phase = .waiting
    /// Audio length in seconds (known after the first probe).
    public private(set) var duration: TimeInterval?
    public private(set) var segmentsTotal = 0
    public private(set) var segmentsDone = 0
    /// 0…1 of the audio transcribed (or given up on).
    public private(set) var fraction: Double = 0
    /// Finished text so far, in order (post-processed).
    public private(set) var paragraphs: [TranscriptParagraph] = []
    public private(set) var failedSegments: [FailedSegment] = []
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    /// Seconds still to go, once there is enough to estimate from.
    public private(set) var estimatedRemaining: TimeInterval?
    /// The saved transcript.
    public private(set) var transcriptID: UUID?
    /// Why the job is `.failed`.
    public private(set) var failureKind: FailureKind?
    /// Speaker labels were asked for but cannot be produced for this file/engine.
    public private(set) var speakersUnavailable = false
    /// Whole file in one request (speaker labels): no per-segment progress.
    public private(set) var singleRequest = false
    /// Paused because the app went to the background (resumes by itself).
    public internal(set) var autoPaused = false

    public var isActive: Bool { phase == .preparing || phase == .transcribing || phase == .finishing }
    public var longForm: Bool { (duration ?? 0) >= 3600 }

    @ObservationIgnored private var manifest: JobManifest
    @ObservationIgnored private let environment: TranscriptionEnvironment
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var scheduler: SegmentScheduler?
    @ObservationIgnored private var stopReason: Phase?
    @ObservationIgnored private var results: [Int: TimedText] = [:]
    @ObservationIgnored private var processed: [SegmentTranscript] = []
    @ObservationIgnored private var speakers = SpeakerMap()
    @ObservationIgnored private var assembler: TranscriptAssembler?
    @ObservationIgnored private var runStart: Date?
    @ObservationIgnored private var resolvedAtRunStart: TimeInterval = 0
    @ObservationIgnored var onSettled: ((TranscriptionJob) -> Void)?

    var folder: URL { environment.workRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    private var manifestURL: URL { folder.appendingPathComponent("manifest.json") }

    /// A new job for `url` (title = file name without extension).
    init(url: URL, engine: STTProviderKind, options: TranscriptionOptions, environment: TranscriptionEnvironment) {
        let id = UUID()
        let title = url.deletingPathExtension().lastPathComponent
        let created = Date()
        let ext = url.pathExtension.lowercased()
        self.id = id
        self.environment = environment
        self.title = title
        createdAt = created
        sourceExtension = ext
        self.engine = engine
        self.options = options
        sourceURL = url
        manifest = JobManifest(id: id, title: title, sourceExtension: ext, sourcePath: url.path,
                               sourceBookmark: Self.bookmark(for: url), created: created, engine: engine, options: options)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        persist()
    }

    /// A job read back from disk (after a relaunch).
    init?(folder: URL, environment: TranscriptionEnvironment) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(JobManifest.self, from: data) else { return nil }
        self.manifest = manifest
        self.environment = environment
        id = manifest.id
        createdAt = manifest.created
        title = manifest.title
        sourceExtension = manifest.sourceExtension
        engine = manifest.engine
        options = manifest.options
        duration = manifest.duration
        singleRequest = manifest.singleRequest ?? false
        speakersUnavailable = manifest.speakersUnavailable
        transcriptID = manifest.transcriptID
        sourceURL = Self.resolveSource(manifest)
        for index in manifest.completed {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(Self.resultName(index))),
               let text = try? JSONDecoder().decode(TimedText.self, from: data) {
                results[index] = text
            } else {
                self.manifest.completed.remove(index) // result file lost: transcribe again
            }
        }
        switch manifest.state {
        case .done: phase = .done
        case .failed:
            phase = .failed(manifest.fatalMessage ?? ProviderError.network("restored").errorDescription ?? "")
            failureKind = manifest.fatalKind ?? .other
        case .active, .paused: phase = .paused
        }
        refreshProgress()
        rebuildText()
    }

    // MARK: Control

    /// Starts or continues (queued, paused, failed). Finished segments are not redone.
    func start(retryingFailures: Bool = false) {
        guard runTask == nil else { return }
        if retryingFailures {
            manifest.failures.removeAll()
            processed.removeAll()
            speakers = SpeakerMap()
        }
        autoPaused = false
        stopReason = nil
        manifest.state = .active
        manifest.fatalMessage = nil
        manifest.fatalKind = nil
        failureKind = nil
        persist()
        if startedAt == nil { startedAt = Date() }
        finishedAt = nil
        phase = manifest.preparationComplete || !manifest.segments.isEmpty ? .transcribing : .preparing
        runTask = Task { [weak self] in await self?.run() }
    }

    public func cancel() {
        stop(.cancelled)
    }

    /// Stops without losing work (iOS background time ran out).
    func pause(auto: Bool) {
        guard isActive || phase == .waiting else { return }
        autoPaused = auto
        if runTask == nil {
            phase = .paused
            manifest.state = .paused
            persist()
            return
        }
        stop(.paused)
    }

    private func stop(_ reason: Phase) {
        stopReason = reason
        if let scheduler { Task { await scheduler.cancel() } }
        runTask?.cancel()
        if runTask == nil { settle(reason) }
    }

    /// Queued again (resume while another file runs).
    func setWaiting() {
        autoPaused = false
        phase = .waiting
    }

    /// Deletes the work folder (segment audio and results). The saved transcript stays.
    func discardWork() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Run

    private enum ProducerEnd: Sendable {
        case finished
        case failed(Error)
        case cancelled
    }

    private func run() async {
        runStart = Date()
        resolvedAtRunStart = resolvedSeconds
        DiagLog.log("transcribe", "job start ext=\(sourceExtension) engine=\(engine.rawValue) resume=\(!manifest.segments.isEmpty) prepared=\(manifest.segments.count) done=\(manifest.completed.count)")

        let transcriber: any FileTranscriber
        do {
            transcriber = try environment.makeTranscriber(engine)
        } catch {
            finish(fatal: SegmentFailureKind.message(for: error), kind: Self.failureKind(for: error))
            return
        }

        var needsSource = !manifest.preparationComplete
        var accessing = false
        if needsSource {
            guard let url = sourceURL else {
                finish(fatal: TranscriptionError.sourceMissing.errorDescription ?? "", kind: .file)
                return
            }
            accessing = url.startAccessingSecurityScopedResource()
        }
        defer { if accessing { sourceURL?.stopAccessingSecurityScopedResource() } }

        if manifest.singleRequest == nil, let url = sourceURL {
            do {
                let probe = try await environment.probe(url)
                decideMode(probe: probe, capabilities: transcriber.capabilities)
            } catch {
                finish(fatal: SegmentFailureKind.message(for: error), kind: Self.failureKind(for: error))
                return
            }
            if Task.isCancelled { settle(stopReason ?? .cancelled); return }
        }
        assembler = TranscriptAssembler(postProcess: environment.postProcessor(options.language),
                                        diarized: singleRequest && options.speakers)

        let folder = self.folder
        let keyterms = environment.keyterms()
        let language = options.language.code
        let diarize = singleRequest && options.speakers
        let scheduler = SegmentScheduler(
            concurrency: singleRequest ? 1 : environment.concurrency, retry: environment.retry,
            transcribe: { segment in
                let started = Date()
                let text = try await transcriber.transcribe(
                    file: folder.appendingPathComponent(segment.fileName),
                    request: FileSTTRequest(languageCode: language, keyterms: keyterms, diarize: diarize,
                                            audioSeconds: segment.duration))
                DiagLog.log("transcribe", "segment \(segment.index) ok ms=\(Int(Date().timeIntervalSince(started) * 1000)) audio=\(Int(segment.duration))s timing=\(text.granularity.rawValue) units=\(text.units.count)")
                return text
            },
            deliver: { [weak self] index, outcome in await self?.didResolve(index, outcome) },
            sleep: environment.sleep)
        self.scheduler = scheduler

        for segment in manifest.segments where !manifest.completed.contains(segment.index) && manifest.failures[segment.index] == nil {
            if segment.bytes == 0 { didResolve(segment.index, .success(.empty)); continue }
            await scheduler.enqueue(segment)
        }

        if needsSource, let url = sourceURL {
            let resume = resumePoint()
            let total = manifest.duration.map { Int($0 * 16_000) }
            let single = singleRequest
            let environment = self.environment
            let producerEnd: ProducerEnd = await withTaskGroup(of: ProducerEnd.self) { group in
                group.addTask {
                    do {
                        try await Self.prepare(url: url, resume: resume, totalSamples: total, single: single, folder: folder,
                                               environment: environment) { [weak self] segment in
                            await self?.didPrepare(segment, scheduler: scheduler)
                        }
                        await scheduler.closeInput()
                        return .finished
                    } catch {
                        await scheduler.cancel()
                        return error is CancellationError ? .cancelled : .failed(error)
                    }
                }
                let completion = await scheduler.waitUntilDone()
                if completion != .finished { group.cancelAll() }
                var end = ProducerEnd.cancelled
                for await value in group { end = value }
                return end
            }
            switch producerEnd {
            case .finished:
                manifest.preparationComplete = true
                if manifest.segments.isEmpty {
                    finish(fatal: TranscriptionError.empty.errorDescription ?? "", kind: .file)
                    return
                }
                segmentsTotal = manifest.segments.count
                // The decoded length is exact; the container's duration can be an estimate (VBR MP3).
                if let end = manifest.segments.map(\.end).max() {
                    duration = end
                    manifest.duration = end
                }
                persist()
            case .failed(let error):
                if stopReason == nil, (error as? TranscriptionError) == .interrupted {
                    autoPaused = true
                    stopReason = .paused
                } else if stopReason == nil {
                    finish(fatal: SegmentFailureKind.message(for: error), kind: Self.failureKind(for: error))
                    return
                }
            case .cancelled:
                break
            }
            needsSource = false
        } else {
            await scheduler.closeInput()
        }

        let completion = await scheduler.waitUntilDone()
        self.scheduler = nil
        if let reason = stopReason {
            settle(reason)
            return
        }
        switch completion {
        case .cancelled:
            settle(.cancelled)
        case .fatal(let message):
            // The scheduler only stops for keys, quota and engine settings.
            finish(fatal: message, kind: .settings)
        case .finished:
            await finishSuccessfully()
        }
    }

    /// Decides single-request mode (speaker labels) and the planned number of segments.
    private func decideMode(probe: SourceProbe, capabilities: FileTranscriptionCapabilities) {
        duration = probe.duration
        manifest.duration = probe.duration
        let fits = probe.duration.map { $0 <= (capabilities.maxRequestSeconds ?? 0) } ?? false
        let single = options.speakers && capabilities.diarization && fits
        singleRequest = single
        speakersUnavailable = options.speakers && !single
        manifest.singleRequest = single
        manifest.speakersUnavailable = speakersUnavailable
        manifest.plannedSegments = single ? 1 : environment.policy.plannedCount(duration: probe.duration ?? 0)
        segmentsTotal = manifest.plannedSegments ?? 1
        persist()
        DiagLog.log("transcribe", "probe duration=\(Int(probe.duration ?? -1))s video=\(probe.hasVideo) single=\(single) planned=\(segmentsTotal) speakersUnavailable=\(speakersUnavailable)")
    }

    private func resumePoint() -> SegmenterResumePoint? {
        guard let last = manifest.segments.max(by: { $0.index < $1.index }) else { return nil }
        let cut = Int((last.end * 16_000).rounded())
        let overlap = Int((last.trailingOverlap * 16_000).rounded())
        return SegmenterResumePoint(index: last.index + 1, cutSample: cut, leadingOverlapSamples: overlap)
    }

    /// Decode → segment → encode, off the main actor. Calls `onSegment` for each finished file.
    nonisolated private static func prepare(url: URL, resume: SegmenterResumePoint?, totalSamples: Int?, single: Bool,
                                            folder: URL, environment: TranscriptionEnvironment,
                                            onSegment: @Sendable (SegmentInfo) async -> Void) async throws {
        let startSeconds = Double(resume?.sourceStartSample ?? 0) / 16_000
        let source = try await environment.openSource(url, startSeconds)
        let sink = FileSegmentSink(folder: folder, makeWriter: environment.makeWriter)
        defer { sink.discardOpen() }
        let segmenter = QuietPointSegmenter(policy: environment.policy, totalSamples: totalSamples,
                                            singleSegment: single, resume: resume, sink: sink)
        let started = Date()
        var samples = 0
        while let chunk = try source.read() {
            try Task.checkCancellation()
            samples += chunk.count
            try segmenter.push(chunk)
            for segment in sink.takeFinished() { await onSegment(segment) }
        }
        try Task.checkCancellation()
        try segmenter.finish()
        for segment in sink.takeFinished() { await onSegment(segment) }
        let hard = segmenter.cuts.filter(\.hard).count
        DiagLog.log("transcribe", "prepared audio=\(samples / 16_000)s in \(Int(Date().timeIntervalSince(started) * 1000))ms cuts=\(segmenter.cuts.count) hard=\(hard) peakBuffer=\(segmenter.peakBufferedSamples / 16_000)s")
    }

    private func didPrepare(_ segment: SegmentInfo, scheduler: SegmentScheduler) async {
        guard stopReason == nil else { return }
        manifest.segments.append(segment)
        if segmentsTotal < manifest.segments.count { segmentsTotal = manifest.segments.count }
        persist()
        if phase == .preparing { phase = .transcribing }
        DiagLog.log("transcribe", "segment \(segment.index) prepared \(String(format: "%.1f", segment.start))–\(String(format: "%.1f", segment.end))s bytes=\(segment.bytes) overlap=\(segment.leadingOverlap > 0 || segment.trailingOverlap > 0)\(segment.bytes == 0 ? " silent" : "")")
        if segment.bytes == 0 {
            // Silent segment (see FileSegmentSink): nothing to upload.
            didResolve(segment.index, .success(.empty))
        } else {
            await scheduler.enqueue(segment)
        }
    }

    private func didResolve(_ index: Int, _ outcome: SegmentOutcome) {
        switch outcome {
        case .success(let text):
            results[index] = text
            manifest.completed.insert(index)
            manifest.failures[index] = nil
            if let data = try? JSONEncoder().encode(text) {
                try? data.write(to: folder.appendingPathComponent(Self.resultName(index)), options: .atomic)
            }
        case .failed(let message):
            manifest.failures[index] = message
        }
        persist()
        refreshProgress()
        rebuildText()
    }

    private func finishSuccessfully() async {
        phase = .finishing
        rebuildText()
        let record = makeRecord()
        guard environment.store.save(record) else {
            finish(fatal: TranscriptionError.storage.errorDescription ?? "", kind: .other)
            return
        }
        transcriptID = record.id
        manifest.transcriptID = record.id
        manifest.state = .done
        persist()
        finishedAt = Date()
        phase = .done
        estimatedRemaining = nil
        let seconds = Int(finishedAt!.timeIntervalSince(startedAt ?? finishedAt!))
        DiagLog.log("transcribe", "job done segments=\(manifest.segments.count) failed=\(manifest.failures.count) wall=\(seconds)s chars=\(record.characterCount)")
        if manifest.failures.isEmpty { discardWork() }
        runTask = nil
        onSettled?(self)
    }

    private func finish(fatal message: String, kind: FailureKind) {
        manifest.state = .failed
        manifest.fatalMessage = message
        manifest.fatalKind = kind
        failureKind = kind
        persist()
        DiagLog.log("transcribe", "job failed segmentsDone=\(manifest.completed.count)/\(manifest.segments.count)")
        settle(.failed(message))
    }

    /// Ends a run in `phase` (paused / cancelled / failed).
    private func settle(_ reason: Phase) {
        scheduler = nil
        runTask = nil
        estimatedRemaining = nil
        switch reason {
        case .cancelled:
            discardWork()
            DiagLog.log("transcribe", "job cancelled")
        case .paused:
            manifest.state = .paused
            persist()
            DiagLog.log("transcribe", "job paused auto=\(autoPaused) done=\(manifest.completed.count)/\(manifest.segments.count)")
        default:
            break
        }
        phase = reason
        onSettled?(self)
    }

    // MARK: Progress and text

    private var resolvedSeconds: TimeInterval {
        manifest.segments.reduce(0) { total, segment in
            let resolved = manifest.completed.contains(segment.index) || manifest.failures[segment.index] != nil
            return resolved ? total + (segment.end - segment.ownStart) : total
        }
    }

    private func refreshProgress() {
        segmentsDone = manifest.completed.count + manifest.failures.count
        segmentsTotal = max(segmentsTotal, manifest.preparationComplete ? manifest.segments.count : (manifest.plannedSegments ?? 0),
                            manifest.segments.count)
        if manifest.preparationComplete { segmentsTotal = manifest.segments.count }
        let total = duration ?? manifest.segments.last?.end ?? 0
        fraction = total > 0 ? min(1, resolvedSeconds / total) : 0
        failedSegments = manifest.failures.keys.sorted().compactMap { index in
            guard let segment = manifest.segments.first(where: { $0.index == index }) else { return nil }
            return FailedSegment(index: index, start: segment.ownStart, end: segment.end, message: manifest.failures[index] ?? "")
        }
        if let runStart, total > 0, !singleRequest {
            let doneThisRun = resolvedSeconds - resolvedAtRunStart
            let elapsed = Date().timeIntervalSince(runStart)
            if doneThisRun > 0, elapsed > 1 {
                estimatedRemaining = max(0, (total - resolvedSeconds) / (doneThisRun / elapsed))
            }
        }
    }

    /// Extends the processed prefix as far as the results allow and republishes `paragraphs`.
    private func rebuildText() {
        if assembler == nil {
            assembler = TranscriptAssembler(postProcess: environment.postProcessor(options.language),
                                            diarized: (manifest.singleRequest ?? false) && options.speakers)
        }
        guard let assembler else { return }
        let segments = manifest.segments.sorted { $0.index < $1.index }
        var changed = false
        while processed.count < segments.count {
            let k = processed.count
            let segment = segments[k]
            let failed = manifest.failures[segment.index] != nil
            guard failed || results[segment.index] != nil else { break }
            var next: TimedText?
            if segment.trailingOverlap > 0 {
                guard k + 1 < segments.count else { break }
                let following = segments[k + 1].index
                if manifest.failures[following] == nil {
                    guard let result = results[following] else { break }
                    next = result
                }
            }
            if failed {
                processed.append(.missing(segment))
            } else {
                let previous = k > 0 ? results[segments[k - 1].index] : nil
                processed.append(assembler.process(segment: segment, result: results[segment.index]!,
                                                   previous: previous, next: next, speakers: &speakers))
            }
            changed = true
        }
        if changed || paragraphs.isEmpty {
            paragraphs = processed.flatMap(\.paragraphs)
        }
    }

    private func makeRecord() -> TranscriptRecord {
        let granularity = processed.map(\.granularity).max() ?? .none
        let hasSpeakers = singleRequest && options.speakers && paragraphs.contains { $0.speaker != nil }
        return TranscriptRecord(id: manifest.transcriptID ?? UUID(), title: title, date: manifest.created,
                                duration: duration ?? manifest.segments.last?.end ?? 0, engine: engine, options: options,
                                granularity: granularity, hasSpeakers: hasSpeakers, paragraphs: paragraphs,
                                cues: processed.flatMap(\.cues), sourceExtension: sourceExtension)
    }

    // MARK: Files

    private func persist() {
        guard phase != .cancelled else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            DiagLog.log("transcribe", "manifest write failed (\(type(of: error)))")
        }
    }

    static func failureKind(for error: Error) -> FailureKind {
        switch error {
        case TranscriptionError.storage, TranscriptionError.interrupted: return .other
        case is TranscriptionError: return .file
        case ProviderError.missingAPIKey, is CustomSTTError: return .settings
        default:
            if case .fatal = SegmentFailureKind.classify(error) { return .settings }
            return .other
        }
    }

    static func resultName(_ index: Int) -> String { String(format: "result-%04d.json", index) }

    private static func bookmark(for url: URL) -> Data? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    private static func resolveSource(_ manifest: JobManifest) -> URL? {
        if let data = manifest.sourceBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        guard let path = manifest.sourcePath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

extension SegmentFailureKind {
    /// User-facing text for an error that ends a job.
    static func message(for error: Error) -> String {
        if let error = error as? TranscriptionError { return error.errorDescription ?? "" }
        switch classify(error) {
        case .fatal(let message), .segment(let message), .transient(let message): return message
        case .rateLimited(_, let message): return message
        case .cancelled: return ProviderError.cancelled.errorDescription ?? ""
        }
    }
}

/// Writes each segment to its own file and reports it when closed. Entirely silent segments
/// (peak below about -54 dBFS) are not kept: they are reported with `bytes == 0` and never uploaded.
final class FileSegmentSink: SegmentSink, @unchecked Sendable {
    static let silencePeak: Float = 0.002

    private let folder: URL
    private let makeWriter: (URL) throws -> any SegmentAudioWriter
    private var writer: (any SegmentAudioWriter)?
    private var current: (index: Int, start: Int, overlap: Int)?
    private var peak: Float = 0
    private var finished: [SegmentInfo] = []

    init(folder: URL, makeWriter: @escaping (URL) throws -> any SegmentAudioWriter) {
        self.folder = folder
        self.makeWriter = makeWriter
    }

    func beginSegment(index: Int, startSample: Int, leadingOverlapSamples: Int) throws {
        let base = folder.appendingPathComponent(String(format: "segment-%04d", index))
        do { writer = try makeWriter(base) } catch { throw TranscriptionError.storage }
        current = (index, startSample, leadingOverlapSamples)
        peak = 0
    }

    func appendSamples(_ samples: ArraySlice<Float>) throws {
        guard let writer else { return }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            var value: Float = 0
            vDSP_maxmgv(base, 1, &value, vDSP_Length(buffer.count))
            peak = max(peak, value)
        }
        do { try writer.append(samples) } catch { throw TranscriptionError.storage }
    }

    func endSegment(index: Int, endSample: Int, trailingOverlapSamples: Int) throws {
        guard let writer, let current else { return }
        self.writer = nil
        self.current = nil
        let bytes: Int
        do { bytes = try writer.finish() } catch { throw TranscriptionError.storage }
        let silent = peak < Self.silencePeak || endSample <= current.start
        if silent { try? FileManager.default.removeItem(at: writer.url) }
        finished.append(SegmentInfo(index: index, start: Double(current.start) / 16_000, end: Double(endSample) / 16_000,
                                    leadingOverlap: Double(current.overlap) / 16_000,
                                    trailingOverlap: Double(trailingOverlapSamples) / 16_000,
                                    fileName: writer.url.lastPathComponent, bytes: silent ? 0 : bytes))
    }

    func takeFinished() -> [SegmentInfo] {
        defer { finished.removeAll() }
        return finished
    }

    /// Cancelled mid-segment: delete the partial file.
    func discardOpen() {
        writer?.discard()
        writer = nil
        current = nil
    }
}

// MARK: - Display-only state (screenshots, previews, demo data)

extension TranscriptionEnvironment {
    /// An environment that never decodes or uploads anything (for display-only jobs).
    public static func preview(store: TranscriptStore) -> TranscriptionEnvironment {
        TranscriptionEnvironment(
            workRoot: FileManager.default.temporaryDirectory.appendingPathComponent("ScriberPreviewWork", isDirectory: true),
            store: store,
            makeTranscriber: { _ in throw ProviderError.cancelled },
            probe: { _ in SourceProbe(duration: nil) },
            openSource: { _, _ in throw TranscriptionError.unreadable },
            makeWriter: { try WAVSegmentWriter(baseURL: $0) },
            keyterms: { [] },
            postProcessor: { _ in .identity })
    }
}

extension TranscriptionJob {
    /// A job frozen in the given state. It is never started and never touches an engine.
    public static func preview(title: String, sourceExtension: String, phase: Phase, duration: TimeInterval?,
                               segmentsDone: Int = 0, segmentsTotal: Int = 0, fraction: Double = 0,
                               paragraphs: [TranscriptParagraph] = [], failedSegments: [FailedSegment] = [],
                               startedAt: Date? = nil, estimatedRemaining: TimeInterval? = nil,
                               singleRequest: Bool = false, speakersUnavailable: Bool = false,
                               autoPaused: Bool = false, transcriptID: UUID? = nil, failureKind: FailureKind? = nil,
                               engine: STTProviderKind = .elevenLabsScribe, options: TranscriptionOptions = .init(),
                               environment: TranscriptionEnvironment) -> TranscriptionJob {
        let url = URL(fileURLWithPath: "/dev/null/\(title).\(sourceExtension)")
        let job = TranscriptionJob(url: url, engine: engine, options: options, environment: environment)
        job.discardWork()
        job.phase = phase
        job.duration = duration
        job.segmentsDone = segmentsDone
        job.segmentsTotal = segmentsTotal
        job.fraction = fraction
        job.paragraphs = paragraphs
        job.failedSegments = failedSegments
        job.startedAt = startedAt
        job.estimatedRemaining = estimatedRemaining
        job.singleRequest = singleRequest
        job.speakersUnavailable = speakersUnavailable
        job.autoPaused = autoPaused
        job.transcriptID = transcriptID
        job.failureKind = failureKind
        return job
    }

    /// A failed segment for display-only jobs.
    public static func previewFailure(index: Int, start: TimeInterval, end: TimeInterval, message: String) -> FailedSegment {
        FailedSegment(index: index, start: start, end: end, message: message)
    }
}
