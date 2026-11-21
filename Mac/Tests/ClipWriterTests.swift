import AVFoundation
import XCTest

final class ClipWriterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func sine(seconds: Double, rate: Double, amplitude: Float = 0.5, frequency: Double = 440) -> [Float] {
        let count = Int(seconds * rate)
        return (0..<count).map { Float(sin(2 * Double.pi * frequency * Double($0) / rate)) * amplitude }
    }

    /// Feeds `samples` in tap-sized chunks.
    private func feed(_ writer: ClipWriter, _ samples: [Float], rate: Double, chunk: Int = 1024) {
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            writer.append(Array(samples[index..<end]), sampleRate: rate)
            index = end
        }
    }

    func testOneSecondAt48kBecomesSixteenKilohertzAAC() throws {
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("a"))
        XCTAssertEqual(writer.format, .aac)
        XCTAssertEqual(writer.url.pathExtension, "m4a")
        feed(writer, sine(seconds: 1, rate: 48_000), rate: 48_000)
        XCTAssertGreaterThan(writer.displayLevel, 0.5)
        let summary = try XCTUnwrap(writer.finish())
        XCTAssertEqual(summary.duration, 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(summary.peakLevel, ClipPolicy.silenceLevel)
        XCTAssertEqual(summary.rateChanges, 0)
        XCTAssertEqual(ClipPolicy.verdict(duration: summary.duration, peakLevel: summary.peakLevel), .keep)

        // A finished, readable 16 kHz mono AAC file of about a second.
        let file = try AVAudioFile(forReading: summary.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Double(file.length), 16_000, accuracy: 2_048)
        XCTAssertEqual(summary.fileBytes, try summary.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// Real-time transcription gets exactly the 16 kHz samples the file gets, tail included,
    /// across a mid-clip rate change, and nothing after a discard.
    func testStreamSinkReceivesExactlyWhatIsWritten() throws {
        let received = SampleCounter()
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("s"), preferred: .wav,
                                    streamSink: { received.add($0) })
        feed(writer, sine(seconds: 0.5, rate: 48_000), rate: 48_000)
        feed(writer, sine(seconds: 0.5, rate: 44_100), rate: 44_100)
        let summary = try XCTUnwrap(writer.finish())
        XCTAssertEqual(summary.rateChanges, 1)
        XCTAssertEqual(received.count, Int((summary.duration * 16_000).rounded()))
        XCTAssertGreaterThan(received.peak, 0.4)

        let discarded = SampleCounter()
        let other = try ClipWriter(baseURL: folder.appendingPathComponent("d"), streamSink: { discarded.add($0) })
        feed(other, sine(seconds: 0.2, rate: 48_000), rate: 48_000)
        let before = discarded.count
        other.discard()
        other.append(sine(seconds: 0.2, rate: 48_000), sampleRate: 48_000)
        XCTAssertEqual(discarded.count, before, "no tail flush and nothing after discard")
    }

    func testWAVFallbackHasAValidHeader() throws {
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("w"), preferred: .wav)
        XCTAssertEqual(writer.url.pathExtension, "wav")
        feed(writer, sine(seconds: 1, rate: 48_000), rate: 48_000)
        let summary = try XCTUnwrap(writer.finish())
        XCTAssertEqual(summary.format, .wav)
        XCTAssertEqual(summary.duration, 1.0, accuracy: 0.01)
        let data = try Data(contentsOf: summary.url)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16_000)
        let dataBytes = data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: dataBytes)), data.count - 44)
    }

    /// 15 minutes must stay under the 25 MB upload limit some providers have. Noise is the worst
    /// case for the encoder; 30 s of it scaled up to 15 minutes must fit with room to spare.
    func testFifteenMinutesOfAACStayUnderTwentyFiveMegabytes() throws {
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("size"))
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<(30 * 16_000)).map { _ in Float.random(in: -0.6...0.6, using: &generator) }
        feed(writer, noise, rate: 16_000, chunk: 4096)
        let summary = try XCTUnwrap(writer.finish())
        let projected = Double(summary.fileBytes) / summary.duration * ClipPolicy.maximumRecordingSeconds
        print("AAC size: \(summary.fileBytes) bytes for \(summary.duration)s → 15 min ≈ \(Int(projected / 1_000_000)) MB")
        XCTAssertLessThan(projected, 25_000_000 * 0.8, "projected 15-minute size \(Int(projected)) bytes")
    }

    func testSampleRateChangeMidClipKeepsTheTimeline() throws {
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("b"))
        feed(writer, sine(seconds: 0.5, rate: 48_000), rate: 48_000)
        // AirPods connected: the input continues at 24 kHz.
        feed(writer, sine(seconds: 0.5, rate: 24_000), rate: 24_000)
        let summary = try XCTUnwrap(writer.finish())
        XCTAssertEqual(summary.rateChanges, 1)
        XCTAssertEqual(summary.duration, 1.0, accuracy: 0.01)
    }

    func testSilenceIsDetected() throws {
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("c"))
        feed(writer, [Float](repeating: 0, count: 48_000), rate: 48_000)
        let summary = try XCTUnwrap(writer.finish())
        XCTAssertEqual(summary.peakLevel, 0)
        XCTAssertEqual(ClipPolicy.verdict(duration: summary.duration, peakLevel: summary.peakLevel), .silent)
    }

    func testQuietNoiseCountsAsSilence() throws {
        // About -60 dBFS: room noise, below the -44 dBFS threshold.
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("d"))
        feed(writer, sine(seconds: 1, rate: 44_100, amplitude: 0.0014), rate: 44_100)
        let summary = try XCTUnwrap(writer.finish())
        XCTAssertLessThan(summary.peakLevel, ClipPolicy.silenceLevel)
        XCTAssertEqual(ClipPolicy.verdict(duration: summary.duration, peakLevel: summary.peakLevel), .silent)
    }

    func testEmptyClipIsRemoved() throws {
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("e"))
        XCTAssertNil(writer.finish())
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.url.path))
    }

    func testDiscardDeletesAndIgnoresLateChunks() throws {
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("f"))
        let url = writer.url
        feed(writer, sine(seconds: 0.2, rate: 48_000), rate: 48_000)
        writer.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // A tap buffer arriving after the stop must not recreate anything.
        writer.append(sine(seconds: 0.1, rate: 48_000), sampleRate: 48_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(writer.displayLevel, 0)
    }

    func testFinishTwiceReturnsNilTheSecondTime() throws {
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("g"))
        feed(writer, sine(seconds: 0.5, rate: 16_000), rate: 16_000)
        XCTAssertNotNil(writer.finish())
        XCTAssertNil(writer.finish())
    }

    func testInvalidInputIsIgnored() throws {
        let writer = try ClipWriter(baseURL: folder.appendingPathComponent("h"))
        XCTAssertEqual(writer.append([], sampleRate: 48_000), 0)
        XCTAssertEqual(writer.append([0.5, 0.5], sampleRate: 0), 0)
        XCTAssertEqual(writer.append([0.5, 0.5], sampleRate: .nan), 0)
        XCTAssertEqual(writer.duration, 0)
    }
}

final class ClipPolicyTests: XCTestCase {
    func testThresholdsMatchIOS() {
        XCTAssertEqual(ClipPolicy.minimumSpeechSeconds, 0.3)
        XCTAssertEqual(ClipPolicy.silenceLevel, 0.12)
        XCTAssertEqual(ClipPolicy.maximumRecordingSeconds, 900, "15 minutes, same as iOS")
    }

    func testVerdicts() {
        XCTAssertEqual(ClipPolicy.verdict(duration: 0.29, peakLevel: 0.9), .tooShort)
        XCTAssertEqual(ClipPolicy.verdict(duration: 0.1, peakLevel: 0), .tooShort, "too short wins over silent")
        XCTAssertEqual(ClipPolicy.verdict(duration: 0.3, peakLevel: 0.119), .silent)
        XCTAssertEqual(ClipPolicy.verdict(duration: 0.3, peakLevel: 0.12), .keep)
        XCTAssertEqual(ClipPolicy.verdict(duration: 12, peakLevel: 0.6), .keep)
    }
}

/// Thread-safe tally for the stream sink.
private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _peak: Float = 0
    func add(_ samples: [Float]) {
        lock.lock()
        _count += samples.count
        _peak = max(_peak, samples.map(abs).max() ?? 0)
        lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    var peak: Float { lock.lock(); defer { lock.unlock() }; return _peak }
}
