import AVFoundation
import Foundation
import ScriberCore

/// Whether a finished clip is worth sending to the speech engine. Same thresholds as iOS
/// (`DictationEngine.minimumSpeechSeconds` / `silenceLevel` / `maximumRecordingSeconds`).
enum ClipPolicy {
    static let minimumSpeechSeconds: TimeInterval = 0.3
    /// Peak metered level (`PCMLevel` scale) below this, ≈ -44 dBFS RMS, counts as silence.
    static let silenceLevel: Float = 0.12
    /// Recording stops by itself after this long and the clip is transcribed (not an error).
    static let maximumRecordingSeconds: TimeInterval = 900

    enum Verdict: String, Equatable {
        case keep
        case tooShort
        case silent
    }

    static func verdict(duration: TimeInterval, peakLevel: Float) -> Verdict {
        if duration < minimumSpeechSeconds { return .tooShort }
        if peakLevel < silenceLevel { return .silent }
        return .keep
    }
}

/// Mono float chunks at whatever rate the input device runs → 16 kHz mono file for the speech
/// engines: AAC in .m4a (like iOS; ≈ 0.3 MB a minute, so a 15-minute clip stays far below the
/// 25 MB upload limit some providers have), or 16-bit WAV if the AAC encoder is unavailable.
///
/// Resampling uses ScriberCore's `StreamingResampler`. Unlike `CaptureAssembler` it accepts a
/// sample-rate change in the middle of a clip (the input device was switched while recording):
/// the old resampler is flushed and a new one continues the same file.
///
/// Real-time transcription taps the same audio: `streamSink` receives every block of 16 kHz samples
/// exactly as it goes into the file (including the resampler tail flushed by `finish()`), so the
/// stream and the clip used for the batch fallback never differ.
///
/// Thread-safe: `append` runs on the audio tap thread, `finish`/`discard` on the main thread.
final class ClipWriter: @unchecked Sendable {
    static let outputRate = 16_000

    enum Format: String, Sendable {
        case aac, wav

        var fileExtension: String { self == .aac ? "m4a" : "wav" }
    }

    struct Summary: Equatable, Sendable {
        var url: URL
        var format: Format
        /// Seconds of 16 kHz audio in the file.
        var duration: TimeInterval
        /// Loudest chunk level (0...1).
        var peakLevel: Float
        /// How many times the input rate changed mid-clip.
        var rateChanges: Int
        var fileBytes: Int
    }

    private enum Sink {
        case aac(AVAudioFile)
        case wav(WAVFileWriter)
    }

    let url: URL
    let format: Format
    private let lock = NSLock()
    private var sink: Sink?
    private var resampler: StreamingResampler?
    private var frames = 0
    private var finished = false
    private var writeFailed = false
    private var peak: Float = 0
    private var smoothed: Float = 0
    private var rateChanges = 0
    /// Called with the writer's lock held (tap thread, or main thread from `finish()`): must be
    /// cheap and must not call back into the writer.
    private let streamSink: (@Sendable ([Float]) -> Void)?

    /// `baseURL` without extension; the writer adds .m4a or .wav.
    init(baseURL: URL, preferred: Format = .aac, streamSink: (@Sendable ([Float]) -> Void)? = nil) throws {
        self.streamSink = streamSink
        let base = baseURL.deletingPathExtension()
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        if preferred == .aac, let file = Self.makeAACFile(base: base) {
            sink = .aac(file)
            url = file.url
            format = .aac
        } else {
            let wavURL = base.appendingPathExtension(Format.wav.fileExtension)
            sink = .wav(try WAVFileWriter(url: wavURL, sampleRate: Self.outputRate))
            url = wavURL
            format = .wav
        }
    }

    /// Appends one chunk; returns its level (0...1).
    @discardableResult
    func append(_ samples: [Float], sampleRate: Double) -> Float {
        guard !samples.isEmpty, sampleRate > 0, sampleRate.isFinite else { return 0 }
        let level = PCMLevel.level(rms: PCMLevel.rms(samples))
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return level }
        if let current = resampler, abs(current.inputRate - sampleRate) > 0.5 {
            write(current.flush())
            resampler = nil
            rateChanges += 1
        }
        let active = resampler ?? StreamingResampler(inputRate: sampleRate, outputRate: Double(Self.outputRate))
        resampler = active
        write(active.process(samples))
        peak = max(peak, level)
        // Fast attack, slow release: a waveform that follows speech without flicker.
        smoothed = level > smoothed ? level : smoothed * 0.75 + level * 0.25
        return level
    }

    /// Smoothed level for the waveform (0...1).
    var displayLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return finished ? 0 : smoothed
    }

    /// Seconds written so far.
    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(frames) / Double(Self.outputRate)
    }

    /// Flushes and closes the file. Returns nil (and deletes the file) if nothing usable was written.
    func finish() -> Summary? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        if let resampler { write(resampler.flush()) }
        resampler = nil
        closeSink()
        guard !writeFailed, frames > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Summary(url: url, format: format, duration: Double(frames) / Double(Self.outputRate),
                       peakLevel: peak, rateChanges: rateChanges, fileBytes: bytes)
    }

    /// Closes and deletes the file.
    func discard() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        resampler = nil
        closeSink()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Sink (call with `lock` held)

    private func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        // The stream does not depend on the file: it keeps going even if a file write failed.
        streamSink?(samples)
        guard !writeFailed, let sink else { return }
        do {
            switch sink {
            case .aac(let file):
                let format = file.processingFormat
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else {
                    writeFailed = true
                    return
                }
                samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress!, count: samples.count)
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                try file.write(from: buffer)
            case .wav(let writer):
                try writer.append(samples)
            }
            frames += samples.count
        } catch {
            writeFailed = true
        }
    }

    private func closeSink() {
        switch sink {
        case .aac(let file)?:
            if #available(macOS 15.0, *) { file.close() }
            // Before macOS 15 the AAC file is finalized when it deallocates: this was the only
            // strong reference, released right below.
        case .wav(let writer)?:
            do { try writer.finish() } catch { writeFailed = true }
        case nil:
            break
        }
        sink = nil
    }

    // MARK: AAC

    private static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Double(outputRate),
        AVNumberOfChannelsKey: 1,
    ]

    private static func makeAACFile(base: URL) -> AVAudioFile? {
        let url = base.appendingPathExtension(Format.aac.fileExtension)
        do {
            // No explicit bitrate: at 16 kHz mono the encoder default is its floor (same as iOS).
            return try AVAudioFile(forWriting: url, settings: aacSettings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Creates and deletes a throwaway AAC file so the encoder is loaded before the first clip
    /// (the first encoder setup in a process takes a few hundred ms). Returns the milliseconds.
    @discardableResult
    static func prewarmEncoder() -> Int {
        let started = DispatchTime.now().uptimeNanoseconds
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("scriber-prewarm-\(UUID().uuidString)")
        if let file = makeAACFile(base: base) {
            if #available(macOS 15.0, *) { file.close() }
            try? FileManager.default.removeItem(at: file.url)
        }
        return Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
    }
}
