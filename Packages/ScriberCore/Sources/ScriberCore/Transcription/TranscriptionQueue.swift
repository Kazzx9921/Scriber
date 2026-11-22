import Foundation
import Observation
import ScriberShared

/// Files waiting to be transcribed, one at a time (each file already sends several segments in
/// parallel). Jobs interrupted by quitting the app come back as paused, with their finished
/// segments; finished jobs with failed segments come back so those can be retried.
@MainActor
@Observable
public final class TranscriptionQueue {
    public private(set) var jobs: [TranscriptionJob] = []
    @ObservationIgnored public let environment: TranscriptionEnvironment
    /// Called when the queue starts or stops having active work (keep the screen awake, begin or
    /// end an iOS background task).
    @ObservationIgnored public var onActivityChange: ((Bool) -> Void)?
    @ObservationIgnored private var wasActive = false
    /// Back in the foreground: a job whose pause is still unwinding continues as soon as it settles.
    @ObservationIgnored private var autoResume = false

    public init(environment: TranscriptionEnvironment, restore: Bool = true) {
        self.environment = environment
        if restore { restoreJobs() }
    }

    /// Display-only queue holding `TranscriptionJob.preview` jobs.
    public init(previewJobs: [TranscriptionJob], environment: TranscriptionEnvironment) {
        self.environment = environment
        jobs = previewJobs
    }

    /// The job that produced a saved transcript, while it is still in the list.
    public func job(forTranscript id: UUID) -> TranscriptionJob? {
        jobs.first { $0.transcriptID == id }
    }

    /// True while a job is preparing, transcribing or finishing.
    public var isActive: Bool { jobs.contains { $0.isActive } }

    /// Adds files with the engine and options chosen now; starts the first if idle.
    @discardableResult
    public func add(_ urls: [URL], engine: STTProviderKind, options: TranscriptionOptions) -> [TranscriptionJob] {
        let added = urls.map { url in
            let job = TranscriptionJob(url: url, engine: engine, options: options, environment: environment)
            job.onSettled = { [weak self] _ in self?.jobSettled() }
            return job
        }
        jobs.append(contentsOf: added)
        DiagLog.log("transcribe", "queue add \(added.count) ext=\(added.map(\.sourceExtension).joined(separator: ",")) engine=\(engine.rawValue) timestamps=\(options.timestamps) speakers=\(options.speakers) lang=\(options.language.rawValue)")
        startNextIfIdle()
        return added
    }

    public func cancel(_ job: TranscriptionJob) {
        job.cancel()
    }

    /// Removes a job from the list (cancelling it if it runs) and deletes its work files. A saved
    /// transcript stays in `TranscriptStore`.
    public func remove(_ job: TranscriptionJob) {
        if job.isActive || job.phase == .waiting { job.cancel() }
        job.discardWork()
        jobs.removeAll { $0.id == job.id }
        startNextIfIdle()
        reportActivity()
    }

    /// Continues a paused or failed job (after the user fixed the key, for example).
    public func resume(_ job: TranscriptionJob) {
        switch job.phase {
        case .paused, .failed:
            if hasRunningJob {
                job.markWaiting()
            } else {
                job.start()
            }
            reportActivity()
        default:
            break
        }
    }

    /// Transcribes only the segments that failed, then updates the saved transcript.
    public func retryFailed(_ job: TranscriptionJob) {
        guard job.phase == .done, !job.failedSegments.isEmpty else { return }
        job.start(retryingFailures: true)
        reportActivity()
    }

    /// iOS: background time is running out. Stops active work without losing finished segments.
    public func pauseAll() {
        autoResume = false
        for job in jobs where job.isActive || job.phase == .waiting { job.pause(auto: true) }
        reportActivity()
    }

    /// iOS: back in the foreground. Continues what `pauseAll` stopped.
    public func resumeAutoPaused() {
        autoResume = true
        let paused = jobs.filter { $0.phase == .paused && $0.autoPaused }
        guard !paused.isEmpty else { return }
        for job in paused { job.markWaiting() }
        startNextIfIdle()
    }

    /// Removes finished and cancelled jobs from the list (their transcripts stay saved).
    public func clearFinished() {
        for job in jobs where job.phase == .cancelled || (job.phase == .done && job.failedSegments.isEmpty) {
            job.discardWork()
        }
        jobs.removeAll { $0.phase == .cancelled || ($0.phase == .done && $0.failedSegments.isEmpty) }
    }

    // MARK: Internals

    private var hasRunningJob: Bool { jobs.contains { $0.isActive } }

    private func startNextIfIdle() {
        defer { reportActivity() }
        guard !hasRunningJob, let next = jobs.first(where: { $0.phase == .waiting }) else { return }
        next.start()
    }

    private func jobSettled() {
        if autoResume {
            for job in jobs where job.phase == .paused && job.autoPaused { job.markWaiting() }
        }
        startNextIfIdle()
    }

    private func reportActivity() {
        let active = isActive || jobs.contains { $0.phase == .waiting }
        guard active != wasActive else { return }
        wasActive = active
        onActivityChange?(active)
    }

    private func restoreJobs() {
        let root = environment.workRoot
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var restored: [TranscriptionJob] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard let job = TranscriptionJob(folder: folder, environment: environment) else {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            if job.phase == .done, job.failedSegments.isEmpty {
                job.discardWork() // saved already; nothing left to retry
                continue
            }
            job.onSettled = { [weak self] _ in self?.jobSettled() }
            restored.append(job)
        }
        jobs = restored.sorted { $0.createdAt < $1.createdAt }
        if !restored.isEmpty {
            DiagLog.log("transcribe", "queue restored \(restored.count) job(s)")
        }
    }
}

extension TranscriptionJob {
    /// Back in line behind the running job.
    func markWaiting() {
        guard phase == .paused || { if case .failed = phase { return true } else { return false } }() else { return }
        setWaiting()
    }
}
