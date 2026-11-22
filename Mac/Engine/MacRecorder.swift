import AVFoundation
import ScriberShared

/// Microphone → 16 kHz mono AAC (`ClipWriter`). A fresh `AVAudioEngine` is built for every
/// recording and released right after, so the microphone is never touched while idle and a new
/// default input device is picked up automatically.
///
/// 設定 → 音訊 → 麥克風: with a pinned device, every engine start (`InputEngine`) uses it when it is
/// connected and usable, else the system default for that start; `route` says which and why.
///
/// If the input device changes or disappears mid-recording (AirPods connect, a USB mic is
/// unplugged), the engine reports a configuration change; the recorder rebuilds the engine — on
/// the pinned device if it is still there, else on the current default — and keeps writing to the
/// same file (the writer handles a new sample rate). If that fails, `onInputLost` tells the owner
/// to finish with what was recorded.
///
/// `silenceGate`: when the start cue plays through speakers, the loudest level after the first
/// `silenceGate` seconds is kept apart (`peakAfterGate`) so the silence check can ignore the cue.
/// The audio itself is never cut.
///
/// Main thread, except the tap block, which only hands samples to the thread-safe writer.
final class MacRecorder: @unchecked Sendable {
    enum Failure: Error {
        case noInputDevice
        case engine(Error)
        case file(Error)
    }

    /// Main thread: the input could not be restarted after a device change. The argument is a log token.
    var onInputLost: ((String) -> Void)?

    private(set) var isRecording = false
    /// "48000Hz/1ch", for the log.
    private(set) var inputDescription = "-"
    /// The input the engine was started on last, and why.
    private(set) var route: InputRoute = .systemDefault(.followSystem)
    /// After `stop()`: the loudest level after the silence gate, nil when there was no gate.
    private(set) var peakAfterGate: Float?

    private let lock = NSLock()
    private var writer: ClipWriter? // guarded by `lock`
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var restarts = 0
    private static let maxRestarts = 5
    private var pinnedUID: String?
    private var logTag = "-"
    // Guarded by `lock` (tap thread + main thread).
    private var gate: TimeInterval?
    private var capturedSeconds: TimeInterval = 0
    private var gatedPeak: Float = 0

    /// Smoothed input level 0...1 for the waveform. Any thread.
    var level: Float {
        lock.lock()
        let current = writer
        lock.unlock()
        return current?.displayLevel ?? 0
    }

    /// Seconds recorded so far.
    var recordedSeconds: TimeInterval {
        lock.lock()
        let current = writer
        lock.unlock()
        return current?.duration ?? 0
    }

    /// Starts the microphone and a new clip next to `baseURL` (extension chosen by the writer).
    /// Returns the clip's file URL. `streamSink` (real-time transcription) receives the clip's
    /// 16 kHz mono samples as they are written, on the audio thread; it must not block.
    /// `pinnedUID`: 設定's microphone (nil: system default). `silenceGate`: see the type comment.
    @discardableResult
    func start(baseURL: URL, pinnedUID: String? = nil, silenceGate: TimeInterval? = nil, logTag: String = "-",
               streamSink: (@Sendable ([Float]) -> Void)? = nil) throws -> URL {
        guard !isRecording else { throw Failure.engine(CocoaError(.featureUnsupported)) }
        let newWriter: ClipWriter
        do {
            newWriter = try ClipWriter(baseURL: baseURL, streamSink: streamSink)
        } catch {
            throw Failure.file(error)
        }
        lock.lock()
        writer = newWriter
        gate = silenceGate
        capturedSeconds = 0
        gatedPeak = 0
        lock.unlock()
        self.pinnedUID = pinnedUID
        self.logTag = logTag
        peakAfterGate = nil
        restarts = 0
        do {
            try startEngine()
        } catch {
            lock.lock()
            writer = nil
            lock.unlock()
            newWriter.discard()
            throw error
        }
        isRecording = true
        return newWriter.url
    }

    /// Stops the microphone and closes the file. nil if nothing usable was written.
    func stop() -> ClipWriter.Summary? {
        guard isRecording else { return nil }
        isRecording = false
        teardownEngine()
        lock.lock()
        let current = writer
        writer = nil
        peakAfterGate = gate == nil ? nil : gatedPeak
        gate = nil
        lock.unlock()
        return current?.finish()
    }

    /// Stops the microphone and deletes the file.
    func discard() {
        guard isRecording else { return }
        isRecording = false
        teardownEngine()
        lock.lock()
        let current = writer
        writer = nil
        lock.unlock()
        current?.discard()
    }

    // MARK: Engine

    private func startEngine() throws {
        let started: InputEngine.Started
        do {
            started = try InputEngine.start(pinnedUID: pinnedUID, tag: "id=\(logTag)") { [weak self] buffer in
                self?.ingest(buffer)
            }
        } catch InputEngine.Failure.noInputDevice(let format) {
            inputDescription = format
            DiagLog.log("rec", "no usable input device (\(format))")
            throw Failure.noInputDevice
        } catch {
            DiagLog.log("rec", "engine start failed \(InputEngine.describe(error))")
            if case InputEngine.Failure.engine(let underlying) = error { throw Failure.engine(underlying) }
            throw Failure.engine(error)
        }
        inputDescription = started.description
        route = started.route
        self.engine = started.engine
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: started.engine, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
        DiagLog.log("rec", "input started \(inputDescription) route=\(route.logDescription) restart=\(restarts)")
    }

    private func teardownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func configurationChanged() {
        guard isRecording else { return }
        let before = inputDescription
        teardownEngine()
        restarts += 1
        guard restarts <= Self.maxRestarts else {
            DiagLog.log("rec", "input changed again (\(restarts)×) → giving up")
            onInputLost?("too-many-changes")
            return
        }
        do {
            try startEngine()
            DiagLog.log("rec", "input device changed mid-recording \(before) → \(inputDescription) "
                        + "route=\(route.logDescription), continuing")
        } catch {
            DiagLog.log("rec", "input device changed mid-recording \(before) → could not restart")
            onInputLost?(error is Failure ? "no-input" : "restart-failed")
        }
    }

    // MARK: Tap thread

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        let format = buffer.format
        let channelCount = Int(format.channelCount)
        let samples: [Float]
        if format.isInterleaved, channelCount > 1 {
            // Rare for AVAudioEngine input; take the first channel.
            let base = channels[0]
            samples = (0..<frames).map { base[$0 * channelCount] }
        } else if channelCount > 1 {
            // Multi-channel interface: use the loudest channel of this buffer, so a microphone on
            // input 2 is not lost behind a silent input 1.
            var best = 0
            var bestEnergy: Float = -1
            for c in 0..<channelCount {
                var energy: Float = 0
                let data = channels[c]
                for i in 0..<frames { energy += data[i] * data[i] }
                if energy > bestEnergy {
                    bestEnergy = energy
                    best = c
                }
            }
            samples = Array(UnsafeBufferPointer(start: channels[best], count: frames))
        } else {
            samples = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        lock.lock()
        let current = writer
        lock.unlock()
        let level = current?.append(samples, sampleRate: format.sampleRate) ?? 0
        lock.lock()
        if let gate {
            capturedSeconds += Double(frames) / max(format.sampleRate, 1)
            // A chunk that ends past the gate counts, even if it starts inside it: errs toward keeping the clip.
            if capturedSeconds > gate { gatedPeak = max(gatedPeak, level) }
        }
        lock.unlock()
    }
}

/// Where clips live: ~/Library/Caches/<bundle id>/Recordings. Deleted after the pipeline; a clip
/// kept for retry is deleted by the next dictation; everything is purged at launch.
struct MacRecordingFiles {
    let directory: URL

    init() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        directory = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.geekaz.Scriber.mac", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Without extension: the writer adds .m4a (or .wav).
    func newClipBaseURL() -> URL {
        directory.appendingPathComponent(UUID().uuidString)
    }

    func delete(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns how many files were removed.
    @discardableResult
    func purgeAll() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for url in items where (try? fm.removeItem(at: url)) != nil { removed += 1 }
        return removed
    }
}
