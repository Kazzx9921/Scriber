#if canImport(AVFoundation)
import Accelerate
import AVFoundation
import Foundation
import ScriberShared

/// Reading user files with AVFoundation: anything it can decode (wav, mp3, m4a, aac, aiff, caf,
/// flac, mp4, mov, m4v, …). Support is decided by trying to open the file, not by its extension.
///
/// Decoding streams: `AVAssetReader` hands out the first audio track already converted to 16 kHz
/// mono Float32 (the reader's own sample-rate conversion and downmix), a buffer at a time, so a
/// file of any length is never held in memory.
public enum AudioIngest {
    static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// Opens the file far enough to know it can be transcribed. Throws `TranscriptionError`.
    public static func probe(_ url: URL) async throws -> SourceProbe {
        let asset = AVURLAsset(url: url)
        let audio: [AVAssetTrack]
        let video: [AVAssetTrack]
        do {
            if try await asset.load(.hasProtectedContent) { throw TranscriptionError.protected }
            audio = try await asset.loadTracks(withMediaType: .audio)
            video = try await asset.loadTracks(withMediaType: .video)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.unreadable
        }
        guard !audio.isEmpty else {
            throw video.isEmpty ? TranscriptionError.unreadable : TranscriptionError.noAudioTrack
        }
        let time = try? await asset.load(.duration)
        let seconds = time.map(CMTimeGetSeconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return SourceProbe(duration: seconds, hasVideo: !video.isEmpty)
    }

    /// A decoder positioned at `start` seconds.
    public static func open(_ url: URL, from start: TimeInterval) async throws -> any PCMSource {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw TranscriptionError.unreadable
        }
        guard let track = tracks.first else { throw TranscriptionError.noAudioTrack }
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let channels = formats.compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }.max() ?? 1
        return try AssetPCMSource(asset: asset, track: track, start: start, sourceChannels: Int(channels))
    }

    /// AAC (.m4a, 16 kHz mono, like dictation clips); WAV if the AAC encoder cannot be created.
    public static func makeSegmentWriter(baseURL: URL) throws -> any SegmentAudioWriter {
        if let aac = try? AACSegmentWriter(baseURL: baseURL) { return aac }
        return try WAVSegmentWriter(baseURL: baseURL)
    }
}

/// `AVAssetReader` over the first audio track, 16 kHz mono Float32.
final class AssetPCMSource: PCMSource, @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    /// The reader downmixes stereo with equal power ((L + R) / √2), which can exceed full scale on
    /// loud, mastered stereo (podcasts); scaling by 1/√2 turns it into the average of the channels.
    private let gain: Float

    init(asset: AVAsset, track: AVAssetTrack, start: TimeInterval, sourceChannels: Int = 1) throws {
        gain = sourceChannels == 2 ? Float(1 / 2.0.squareRoot()) : 1
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscriptionError.unreadable
        }
        // The mix output downmixes any channel layout (5.1 films too) to the requested mono.
        let mix = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: AudioIngest.outputSettings)
        mix.alwaysCopiesSampleData = false
        guard reader.canAdd(mix) else { throw TranscriptionError.unreadable }
        reader.add(mix)
        output = mix
        if start > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16_000), duration: .positiveInfinity)
        }
        guard reader.startReading() else { throw Self.map(reader.error) }
    }

    deinit {
        if reader.status == .reading { reader.cancelReading() }
    }

    func read() throws -> [Float]? {
        while true {
            guard let buffer = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw Self.map(reader.error) }
                return nil
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw TranscriptionError.unreadable }
            if gain != 1 {
                var factor = gain
                vDSP_vsmul(samples, 1, &factor, &samples, 1, vDSP_Length(count))
            }
            var lo: Float = -1, hi: Float = 1
            vDSP_vclip(samples, 1, &lo, &hi, &samples, 1, vDSP_Length(count))
            return samples
        }
    }

    static func map(_ error: Error?) -> TranscriptionError {
        guard let error = error as NSError? else { return .unreadable }
        if error.domain == AVFoundationErrorDomain {
            // AVErrorOperationInterrupted (-11847, iOS: the app went to the background).
            if error.code == -11847 { return .interrupted }
            switch AVError.Code(rawValue: error.code) {
            case .contentIsProtected?, .contentIsNotAuthorized?: return .protected
            default: break
            }
        }
        return .unreadable
    }
}

/// One segment as AAC in .m4a (16 kHz mono), the same settings as dictation clips.
public final class AACSegmentWriter: SegmentAudioWriter {
    public let url: URL
    private var file: AVAudioFile?

    public init(baseURL: URL) throws {
        url = baseURL.deletingPathExtension().appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public func append(_ samples: ArraySlice<Float>) throws {
        guard let file, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw TranscriptionError.storage }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    public func finish() throws -> Int {
        if let file, #available(macOS 15.0, iOS 18.0, *) { file.close() }
        // Earlier systems finalize the file when it deallocates (this is the only reference).
        file = nil
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return size ?? 0
    }

    public func discard() {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}

extension TranscriptionEnvironment {
    /// The real thing: engines from settings and Keychain, AVFoundation decoding, AAC segments,
    /// the personal dictionary and the dictation post-processing.
    public static func live(store: TranscriptStore = .shared, keys: KeychainStore = .shared,
                            workRoot: URL = TranscriptionEnvironment.defaultWorkRoot) -> TranscriptionEnvironment {
        TranscriptionEnvironment(
            workRoot: workRoot, store: store,
            makeTranscriber: { try FileTranscriberFactory.make($0, keys: keys) },
            probe: { try await AudioIngest.probe($0) },
            openSource: { try await AudioIngest.open($0, from: $1) },
            makeWriter: { try AudioIngest.makeSegmentWriter(baseURL: $0) },
            keyterms: TranscriptionEnvironment.dictionaryKeyterms,
            postProcessor: { TranscriptPostProcessor.live(language: $0) })
    }
}

extension TranscriptionQueue {
    /// The app's queue (created on first use; restores interrupted jobs).
    public static let shared = TranscriptionQueue(environment: .live())
}
#endif
