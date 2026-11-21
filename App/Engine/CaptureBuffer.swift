import AVFoundation

// Platform-neutral half of the recorder (no AVAudioSession, no UIKit) so it can be exercised
// on macOS: converts tap buffers to 16 kHz mono, keeps a short pre-roll, meters the level and
// writes clips. Fed from the AVAudioEngine tap thread; begin/end are called from the main thread.

struct CapturedClip: Sendable {
    let url: URL
    /// Seconds of audio captured after `beginClip` (pre-roll excluded).
    let spokenDuration: TimeInterval
    /// Seconds in the file (pre-roll included).
    let fileDuration: TimeInterval
    /// Loudest metered level 0...1 seen after `beginClip`.
    let peakLevel: Float
    let timing: ClipTiming
}

/// How quickly real input reached a clip. Numbers only, for the diagnostic log.
struct ClipTiming: Sendable {
    /// Pre-roll written at the head of the clip, in milliseconds.
    var preRollMillis: Int = 0
    /// Whether that pre-roll contained any non-zero sample (a muted input delivers exact zeros).
    var preRollHadSignal = false
    /// From `beginClip` to the first buffer after it, nil if none arrived.
    var firstBufferMillis: Int?
    /// From `beginClip` to the first buffer with any non-zero sample, nil if none arrived.
    var firstSignalMillis: Int?
    /// Time spent creating the clip file (encoder setup), during which input went to the pre-roll.
    var fileCreateMillis = 0

    var summary: String {
        "fileMs=\(fileCreateMillis) preRollMs=\(preRollMillis) preRollSignal=\(preRollHadSignal) firstBufMs=\(firstBufferMillis.map(String.init) ?? "-") firstSignalMs=\(firstSignalMillis.map(String.init) ?? "-")"
    }
}

enum ClipFormat: String {
    case m4a, wav
}

final class CaptureBuffer: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Audio kept from before the start command, so the first syllable survives the
    /// keyboard → app hop (Darwin notification + main-thread dispatch, typically 20–80 ms).
    static let preRollSeconds: Double = 0.4
    /// Upper bound for level callbacks.
    static let levelInterval: UInt64 = 33_000_000 // ns, ≈ 30 Hz

    let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: CaptureBuffer.sampleRate,
                                     channels: 1, interleaved: false)!

    /// Called on the ingest thread while a clip is open, at most ~30 times a second.
    var onLevel: (@Sendable (Float) -> Void)?

    private let lock = NSLock()
    // Guarded by `lock`.
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var fileFrames: AVAudioFramePosition = 0
    private var spokenFrames: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var smoothed: Float = 0
    private var lastLevelEmit: UInt64 = 0
    private var writeFailed = false
    private var clipOpenedAt: UInt64 = 0
    private var timing = ClipTiming()

    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return file != nil
    }

    // MARK: Ingest (tap thread)

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let converted = convert(buffer) else { return }
        let rms = Self.rms(of: converted)
        let level = Self.level(rms: rms)

        if let file {
            if timing.firstBufferMillis == nil || (timing.firstSignalMillis == nil && rms > Self.signalFloor) {
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds &- clipOpenedAt) / 1_000_000)
                if timing.firstBufferMillis == nil { timing.firstBufferMillis = elapsed }
                if timing.firstSignalMillis == nil, rms > Self.signalFloor { timing.firstSignalMillis = elapsed }
            }
            do {
                try file.write(from: converted)
                fileFrames += AVAudioFramePosition(converted.frameLength)
                spokenFrames += AVAudioFramePosition(converted.frameLength)
            } catch {
                writeFailed = true
            }
            peak = max(peak, level)
            smoothed = level > smoothed ? level : smoothed * 0.75 + level * 0.25
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastLevelEmit >= Self.levelInterval, let onLevel {
                lastLevelEmit = now
                let value = smoothed
                onLevel(value)
            }
        } else {
            appendPreRoll(converted)
        }
    }

    /// Drops converter state and pre-roll, e.g. after the engine was rebuilt.
    func resetInput() {
        lock.lock(); defer { lock.unlock() }
        converter = nil
        converterSource = nil
        preRoll.removeAll()
        preRollFrames = 0
    }

    // MARK: Clips (main thread)

    /// Opens a clip file next to `baseURL` (extension replaced) and writes the pre-roll into it.
    /// Prefers AAC in m4a; falls back to 16-bit wav if the encoder is unavailable.
    @discardableResult
    func beginClip(baseURL: URL) throws -> URL {
        // Creating the file sets up the AAC encoder, which can take a few hundred milliseconds
        // (180–370 ms on a process's first clip in the simulator, ≈15 ms after; see
        // `prewarmEncoder`). Do it before taking the lock:
        // meanwhile the tap keeps filling the pre-roll instead of blocking (a blocked tap thread
        // can drop buffers, i.e. the first syllable).
        let started = DispatchTime.now().uptimeNanoseconds
        let (newFile, url) = try Self.makeFile(baseURL: baseURL, processing: outputFormat)
        let createMillis = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
        lock.lock(); defer { lock.unlock() }
        closeFile()
        file = newFile
        fileURL = url
        fileFrames = 0
        spokenFrames = 0
        peak = 0
        smoothed = 0
        writeFailed = false
        timing = ClipTiming()
        timing.fileCreateMillis = createMillis
        clipOpenedAt = DispatchTime.now().uptimeNanoseconds
        for chunk in preRoll {
            if (try? newFile.write(from: chunk)) != nil { fileFrames += AVAudioFramePosition(chunk.frameLength) }
            if !timing.preRollHadSignal, Self.rms(of: chunk) > Self.signalFloor { timing.preRollHadSignal = true }
        }
        timing.preRollMillis = Int(Double(preRollFrames) / Self.sampleRate * 1000)
        preRoll.removeAll()
        preRollFrames = 0
        return url
    }

    /// Closes the clip. Returns nil if no clip was open or nothing could be written.
    func endClip() -> CapturedClip? {
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL, file != nil else { return nil }
        let clip = CapturedClip(url: url,
                                spokenDuration: Double(spokenFrames) / Self.sampleRate,
                                fileDuration: Double(fileFrames) / Self.sampleRate,
                                peakLevel: peak,
                                timing: timing)
        let failed = writeFailed || fileFrames == 0
        closeFile()
        if failed {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return clip
    }

    /// Returns the timing of the discarded clip (nil if none was open), for the log.
    @discardableResult
    func discardClip() -> ClipTiming? {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL
        let wasOpen = file != nil
        closeFile()
        if let url { try? FileManager.default.removeItem(at: url) }
        return wasOpen ? timing : nil
    }

    // MARK: Helpers (lock held)

    private func closeFile() {
        if let file {
            if #available(iOS 18.0, macOS 15.0, *) { file.close() }
            // Before iOS 18 the file is finalized (AAC trailer written) when it deallocates,
            // which happens right here because this is the only strong reference.
        }
        file = nil
        fileURL = nil
    }

    private func appendPreRoll(_ chunk: AVAudioPCMBuffer) {
        preRoll.append(chunk)
        preRollFrames += chunk.frameLength
        let limit = AVAudioFrameCount(Self.preRollSeconds * Self.sampleRate)
        while preRollFrames > limit, let first = preRoll.first, preRollFrames - first.frameLength >= limit {
            preRoll.removeFirst()
            preRollFrames -= first.frameLength
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = input.format
        if source.sampleRate == outputFormat.sampleRate, source.channelCount == 1,
           source.commonFormat == .pcmFormatFloat32, !source.isInterleaved {
            return Self.copy(input)
        }
        if converter == nil || converterSource != source {
            converter = AVAudioConverter(from: source, to: outputFormat)
            converterSource = source
            // Mono output from multi-channel input: take the first channel rather than letting
            // the converter fail on an unspecified mapping.
            if source.channelCount > 1 { converter?.channelMap = [0] }
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        // `.noDataNow` (not `.endOfStream`) keeps the resampler's state across tap buffers,
        // so there is no click or gap at buffer boundaries.
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private static func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength),
              let src = input.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = input.frameLength
        dst[0].update(from: src[0], count: Int(input.frameLength))
        return out
    }

    /// Any RMS above this (≈ -140 dBFS) is real input; a muted input delivers exact zeros.
    static let signalFloor: Float = 1e-7

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return (sum / Float(n)).squareRoot()
    }

    /// RMS → 0...1 on a -50…0 dBFS scale. Speech sits around 0.4–0.8.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        level(rms: rms(of: buffer))
    }

    static func level(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db + 50) / 50, 0), 1)
    }

    /// Creates and deletes a throwaway clip so the AAC encoder is loaded before the first real
    /// clip (the first encoder setup in a process measured ≈370 ms in the simulator, ≈15 ms after).
    /// Returns the milliseconds it took.
    @discardableResult
    static func prewarmEncoder() -> Int {
        let started = DispatchTime.now().uptimeNanoseconds
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prewarm-\(UUID().uuidString)")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        if let (file, url) = try? makeFile(baseURL: base, processing: format) {
            if #available(iOS 18.0, macOS 15.0, *) { file.close() }
            try? FileManager.default.removeItem(at: url)
        }
        return Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
    }

    static func makeFile(baseURL: URL, processing: AVAudioFormat) throws -> (AVAudioFile, URL) {
        let base = baseURL.deletingPathExtension()
        let aacURL = base.appendingPathExtension(ClipFormat.m4a.rawValue)
        // No explicit bitrate: at 16 kHz mono the encoder default is already its floor
        // (measured ≈ 50 KB per 10 s of noisy audio, within the PRD's 40–80 KB), and an
        // unsupported bitrate would only add a way for this to fail.
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        if let file = try? AVAudioFile(forWriting: aacURL, settings: aac,
                                       commonFormat: .pcmFormatFloat32, interleaved: false) {
            return (file, aacURL)
        }
        try? FileManager.default.removeItem(at: aacURL)
        let wavURL = base.appendingPathExtension(ClipFormat.wav.rawValue)
        let wav: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: wavURL, settings: wav,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        return (file, wavURL)
    }
}
