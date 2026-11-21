import XCTest
@testable import ScriberCore

/// The keyboard's in-keyboard capture path: PCM chunks from WebKit → 16 kHz WAV.
final class PCMCaptureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberPCMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func sine(_ frequency: Double, rate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let n = Int(rate * seconds)
        return (0..<n).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        PCMLevel.rms(Array(x))
    }

    // MARK: PCM16

    func testInt16RoundTripAndClamping() {
        let data = Data([0x00, 0x00, 0x00, 0x80, 0xFF, 0x7F, 0x00, 0x40, 0x01]) // odd trailing byte ignored
        XCTAssertEqual(PCM16.floats(fromLittleEndian: data), [0, -1, Float(32767) / 32768, 0.5])

        let encoded = PCM16.littleEndianData(from: [0, 1, -1, 2, -2, 0.5])
        XCTAssertEqual(Array(encoded), [0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0xFF, 0x7F, 0x00, 0x80, 0x00, 0x40])
    }

    // MARK: Resampler

    func testOutputLengthMatchesRateRatio() {
        for (rate, seconds) in [(48_000.0, 1.0), (44_100.0, 1.0), (48_000.0, 0.37), (24_000.0, 2.0), (8_000.0, 1.0)] {
            let input = [Float](repeating: 0.1, count: Int(rate * seconds))
            let resampler = StreamingResampler(inputRate: rate)
            let out = resampler.process(input) + resampler.flush()
            let expected = Double(input.count) * 16_000 / rate
            XCTAssertEqual(Double(out.count), expected, accuracy: 1, "rate \(rate) × \(seconds) s")
        }
    }

    func testSameRateIsPassthrough() {
        let input = sine(440, rate: 16_000, seconds: 0.1)
        let resampler = StreamingResampler(inputRate: 16_000)
        XCTAssertEqual(resampler.process(input) + resampler.flush(), input)
    }

    func testPassbandSineSurvivesAt48And44k() {
        for rate in [48_000.0, 44_100.0] {
            let input = sine(1_000, rate: rate, seconds: 0.5)
            let resampler = StreamingResampler(inputRate: rate)
            let out = resampler.process(input) + resampler.flush()
            let ideal = sine(1_000, rate: 16_000, seconds: 0.5)
            // Steady state (away from the zero-padded edges): within 1 % of full scale.
            let range = 200..<(min(out.count, ideal.count) - 200)
            let maxError = range.map { abs(out[$0] - ideal[$0]) }.max() ?? 1
            XCTAssertLessThan(maxError, 0.01, "rate \(rate)")
        }
    }

    func testContentAboveOutputNyquistIsRemoved() {
        // 12 kHz cannot be represented at 16 kHz; without filtering it would alias to 4 kHz at full level.
        let input = sine(12_000, rate: 48_000, seconds: 0.5)
        let resampler = StreamingResampler(inputRate: 48_000)
        let out = resampler.process(input) + resampler.flush()
        XCTAssertLessThan(rms(out[200..<(out.count - 200)]), 0.005)
        // Speech-band content (3 kHz) keeps its level.
        let ok = StreamingResampler(inputRate: 48_000)
        let three = ok.process(sine(3_000, rate: 48_000, seconds: 0.5)) + ok.flush()
        XCTAssertEqual(rms(three[200..<(three.count - 200)]), 0.5 / 2.0.squareRoot().float, accuracy: 0.01)
    }

    func testChunkingDoesNotChangeOutput() {
        let input = sine(523, rate: 44_100, seconds: 0.6) + sine(2_000, rate: 44_100, seconds: 0.2)
        let whole = StreamingResampler(inputRate: 44_100)
        let reference = whole.process(input) + whole.flush()

        var chunked: [Float] = []
        let resampler = StreamingResampler(inputRate: 44_100)
        var index = 0
        var sizes = [1, 7, 4096, 128, 3, 2048, 999]
        while index < input.count {
            let size = sizes.removeFirst(); sizes.append(size)
            let end = min(input.count, index + size)
            chunked += resampler.process(Array(input[index..<end]))
            index = end
        }
        chunked += resampler.flush()
        XCTAssertEqual(chunked.count, reference.count)
        for i in 0..<min(chunked.count, reference.count) {
            XCTAssertEqual(chunked[i], reference[i], accuracy: 1e-6, "sample \(i)")
        }
    }

    // MARK: WAV

    func testWAVHeaderLayout() {
        let header = WAVFileWriter.header(sampleRate: 16_000, dataBytes: 3200)
        XCTAssertEqual(header.count, 44)
        func u32(_ o: Int) -> UInt32 { header.subdata(in: o..<o + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
        func u16(_ o: Int) -> UInt16 { header.subdata(in: o..<o + 2).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) } }
        XCTAssertEqual(String(decoding: header[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(u32(4), 36 + 3200)
        XCTAssertEqual(String(decoding: header[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(u32(16), 16)
        XCTAssertEqual(u16(20), 1)       // PCM
        XCTAssertEqual(u16(22), 1)       // mono
        XCTAssertEqual(u32(24), 16_000)  // sample rate
        XCTAssertEqual(u32(28), 32_000)  // byte rate
        XCTAssertEqual(u16(32), 2)       // block align
        XCTAssertEqual(u16(34), 16)      // bits
        XCTAssertEqual(String(decoding: header[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(u32(40), 3200)
    }

    func testAssemblerWritesValid16kWAVFromChunks() throws {
        let url = directory.appendingPathComponent("clip.wav")
        let assembler = try CaptureAssembler(url: url, inputRate: 48_000)
        let input = sine(440, rate: 48_000, seconds: 1.0, amplitude: 0.25)
        var i = 0
        while i < input.count {
            let end = min(input.count, i + 4096)
            try assembler.append(int16LittleEndian: PCM16.littleEndianData(from: Array(input[i..<end])))
            i = end
        }
        let duration = try assembler.finish()
        XCTAssertEqual(duration, 1.0, accuracy: 0.001)
        XCTAssertEqual(assembler.chunkCount, Int((48_000.0 / 4096).rounded(.up)))
        // RMS of a 0.25 sine ≈ 0.177 → ≈ -15 dBFS → (−15 + 50) / 50 ≈ 0.70
        XCTAssertEqual(assembler.peakLevel, 0.70, accuracy: 0.02)

        let file = try Data(contentsOf: url)
        XCTAssertEqual(file.count, 44 + 16_000 * 2)
        XCTAssertEqual(file.prefix(44), WAVFileWriter.header(sampleRate: 16_000, dataBytes: 32_000))
        let samples = PCM16.floats(fromLittleEndian: file.subdata(in: 44..<file.count))
        let ideal = sine(440, rate: 16_000, seconds: 1.0, amplitude: 0.25)
        let maxError = (200..<15_800).map { abs(samples[$0] - ideal[$0]) }.max() ?? 1
        XCTAssertLessThan(maxError, 0.005)
        // finish() twice is harmless.
        XCTAssertEqual(try assembler.finish(), 1.0, accuracy: 0.001)
    }

    func testSilenceAndDiscard() throws {
        let url = directory.appendingPathComponent("silent.wav")
        let assembler = try CaptureAssembler(url: url, inputRate: 44_100)
        try assembler.append(samples: [Float](repeating: 0, count: 4096))
        XCTAssertEqual(assembler.peakLevel, 0)
        try assembler.append(samples: [Float](repeating: 0.001, count: 4096)) // -60 dBFS: below the scale
        XCTAssertEqual(assembler.peakLevel, 0)
        assembler.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try assembler.append(samples: [0.5]), 0) // ignored after discard
    }

    func testLevelScaleMatchesTheApp() {
        XCTAssertEqual(PCMLevel.level(rms: 1), 1)
        XCTAssertEqual(PCMLevel.level(rms: 0), 0)
        XCTAssertEqual(PCMLevel.level(rms: pow(10, -25.0 / 20).float), 0.5, accuracy: 0.001) // -25 dBFS
        XCTAssertEqual(PCMLevel.level(rms: pow(10, -44.0 / 20).float), 0.12, accuracy: 0.001) // the app's silence bar
    }
}

private extension Double {
    var float: Float { Float(self) }
}
