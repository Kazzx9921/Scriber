import AVFoundation
import ScriberShared

/// Microphone → 16 kHz mono AAC (`ClipWriter`). A fresh `AVAudioEngine` is built for every
/// recording and released right after, so the microphone is never touched while idle and a new
/// default input device is picked up automatically.
///
/// If the input device changes or disappears mid-recording (AirPods connect, a USB mic is
/// unplugged), the engine reports a configuration change; the recorder rebuilds the engine on the
/// current default device and keeps writing to the same file (the writer handles a new sample
/// rate). If that fails, `onInputLost` tells the owner to finish with what was recorded.
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

    private let lock = NSLock()
    private var writer: ClipWriter? // guarded by `lock`
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var restarts = 0
    private static let maxRestarts = 5

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
    @discardableResult
    func start(baseURL: URL, streamSink: (@Sendable ([Float]) -> Void)? = nil) throws -> URL {
        guard !isRecording else { throw Failure.engine(CocoaError(.featureUnsupported)) }
        let newWriter: ClipWriter
        do {
            newWriter = try ClipWriter(baseURL: baseURL, streamSink: streamSink)
        } catch {
            throw Failure.file(error)
        }
        lock.lock()
        writer = newWriter
        lock.unlock()
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
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        inputDescription = "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
        // No input device (or one with no input channels): installing a tap would raise.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            DiagLog.log("rec", "no usable input device (\(inputDescription))")
            throw Failure.noInputDevice
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            DiagLog.log("rec", "engine start failed \(MacDiag.error(error)) input=\(inputDescription)")
            throw Failure.engine(error)
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
        DiagLog.log("rec", "input started \(inputDescription) restart=\(restarts)")
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
            DiagLog.log("rec", "input device changed mid-recording \(before) → \(inputDescription), continuing")
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
        current?.append(samples, sampleRate: format.sampleRate)
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
