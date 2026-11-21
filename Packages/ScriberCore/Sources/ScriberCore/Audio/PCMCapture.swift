import Foundation

// Turns the PCM chunks the keyboard's in-keyboard recorder receives (16-bit little-endian mono
// at whatever rate WebKit's AudioContext runs, usually 48 kHz) into a 16 kHz mono 16-bit WAV
// file the STT providers accept. Foundation only, so it is unit-tested with `swift test`.
//
// Memory: samples are resampled and written to disk chunk by chunk; nothing but the resampler's
// short history (< 100 samples) is kept in memory, so a 5-minute dictation costs the same as a
// 2-second one (the keyboard extension is jetsammed far below the app's limit).

/// Level metering shared with the app's recorder (`CaptureBuffer.level(of:)`): RMS mapped to
/// 0...1 on a -50…0 dBFS scale. Speech sits around 0.4–0.8; the app treats a peak below 0.12
/// (≈ -44 dBFS) as silence.
public enum PCMLevel {
    public static func level(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db + 50) / 50, 0), 1)
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

public enum PCM16 {
    /// Little-endian Int16 → Float in -1...1. A trailing odd byte is ignored.
    public static func floats(fromLittleEndian data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(value) / 32768
            }
        }
        return out
    }

    /// Float → little-endian Int16 bytes, clamped, rounded to nearest.
    public static func littleEndianData(from samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            for (i, s) in samples.enumerated() {
                let clamped = min(max(s, -1), 1)
                let scaled = clamped < 0 ? clamped * 32768 : clamped * 32767
                let value = Int16(scaled.rounded()).littleEndian
                raw.storeBytes(of: value, toByteOffset: i * 2, as: Int16.self)
            }
        }
        return data
    }
}

/// Streaming band-limited resampler (windowed sinc, Blackman window, 8 zero crossings each side).
/// Downsampling low-passes at 92 % of the output Nyquist so 48 kHz → 16 kHz does not alias.
/// Output sample `n` corresponds exactly to input time `n * inputRate / outputRate` (no delay),
/// and chunked processing gives the same samples as processing everything at once.
public final class StreamingResampler {
    public let inputRate: Double
    public let outputRate: Double

    private let step: Double          // input samples per output sample
    private let halfWidth: Int        // kernel half width, in input samples
    private let phases: Int           // fractional positions in the table
    private let table: [Float]        // (phases + 1) × taps
    private var taps: Int { 2 * halfWidth }
    private let passthrough: Bool

    private var buffer: [Float] = []  // input samples starting at absolute index `bufferStart`
    private var bufferStart = 0
    private var totalInput = 0
    private var emitted = 0

    public init(inputRate: Double, outputRate: Double = 16_000) {
        precondition(inputRate > 0 && outputRate > 0)
        self.inputRate = inputRate
        self.outputRate = outputRate
        step = inputRate / outputRate
        passthrough = abs(inputRate - outputRate) < 0.5
        let cutoff = min(1.0, outputRate / inputRate) * 0.92 // fraction of the input Nyquist
        let zeroCrossings = 8.0
        halfWidth = passthrough ? 1 : Int((zeroCrossings / cutoff).rounded(.up))
        phases = 256
        var table = [Float]()
        if !passthrough {
            let taps = 2 * halfWidth
            table.reserveCapacity((phases + 1) * taps)
            for p in 0...phases {
                let frac = Double(p) / Double(phases)
                var row = [Double](repeating: 0, count: taps)
                var sum = 0.0
                for j in 0..<taps {
                    // Tap j is input index center - halfWidth + 1 + j; distance = t - k.
                    let d = frac + Double(halfWidth - 1 - j)
                    let x = cutoff * d
                    let sinc = abs(x) < 1e-9 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                    let w = Self.blackman(d / Double(halfWidth))
                    row[j] = cutoff * sinc * w
                    sum += row[j]
                }
                // Unity DC gain at every phase.
                for j in 0..<taps { table.append(Float(row[j] / sum)) }
            }
        }
        self.table = table
    }

    private static func blackman(_ x: Double) -> Double {
        // x in -1...1 → window value; zero outside.
        guard abs(x) < 1 else { return 0 }
        let n = (x + 1) / 2 // 0...1
        return 0.42 - 0.5 * cos(2 * Double.pi * n) + 0.08 * cos(4 * Double.pi * n)
    }

    /// Number of output samples the input seen so far maps to (those with `n * step < totalInput`).
    private var expectedOutputCount: Int {
        Int((Double(totalInput) / step - 1e-9).rounded(.up))
    }

    public func process(_ input: [Float]) -> [Float] {
        totalInput += input.count
        if passthrough {
            emitted += input.count
            return input
        }
        buffer.append(contentsOf: input)
        return drain(limit: nil)
    }

    /// Emits the tail (the last `halfWidth` input samples' worth of output).
    public func flush() -> [Float] {
        if passthrough { return [] }
        buffer.append(contentsOf: [Float](repeating: 0, count: halfWidth + 1))
        let out = drain(limit: expectedOutputCount)
        buffer.removeAll()
        return out
    }

    private func drain(limit: Int?) -> [Float] {
        var out: [Float] = []
        let bufferEnd = bufferStart + buffer.count
        out.reserveCapacity(max(0, Int(Double(bufferEnd - bufferStart) / step) + 1))
        table.withUnsafeBufferPointer { table in
            buffer.withUnsafeBufferPointer { buf in
                while true {
                    if let limit, emitted >= limit { break }
                    let t = Double(emitted) * step
                    var center = Int(t.rounded(.down))
                    var phase = Int(((t - Double(center)) * Double(phases)).rounded())
                    if phase >= phases { phase = 0; center += 1 }
                    let first = center - halfWidth + 1
                    let last = center + halfWidth
                    guard last < bufferEnd else { break }
                    let row = phase * taps
                    var acc: Float = 0
                    for j in 0..<taps {
                        let i = first + j - bufferStart
                        if i >= 0 { acc += buf[i] * table[row + j] } // before the start: silence
                    }
                    out.append(acc)
                    emitted += 1
                }
            }
        }
        // Keep only the history the next output still needs.
        let nextCenter = Int((Double(emitted) * step).rounded(.down))
        let keepFrom = nextCenter - halfWidth
        let drop = min(keepFrom - bufferStart, buffer.count)
        if drop > 0 {
            buffer.removeFirst(drop)
            bufferStart += drop
        }
        return out
    }
}

/// Writes a mono 16-bit PCM WAV file incrementally: a header with placeholder sizes first,
/// samples as they come, the real sizes patched in by `finish()`.
public final class WAVFileWriter {
    public let url: URL
    public let sampleRate: Int
    public private(set) var frameCount = 0
    private var handle: FileHandle?

    public init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, dataBytes: 0)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: PCM16.littleEndianData(from: samples))
        frameCount += samples.count
    }

    /// Patches the RIFF and data sizes and closes the file. Safe to call more than once.
    public func finish() throws {
        guard let handle else { return }
        self.handle = nil
        defer { try? handle.close() }
        let dataBytes = UInt32(clamping: frameCount * 2)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.le32(36 &+ dataBytes))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.le32(dataBytes))
        try handle.synchronize()
    }

    public static func header(sampleRate: Int, dataBytes: Int) -> Data {
        let channels: UInt16 = 1, bits: UInt16 = 16
        let blockAlign = channels * bits / 8
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(le32(UInt32(clamping: 36 + dataBytes)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(le32(16))
        d.append(le16(1)) // PCM
        d.append(le16(channels))
        d.append(le32(UInt32(sampleRate)))
        d.append(le32(UInt32(sampleRate) * UInt32(blockAlign)))
        d.append(le16(blockAlign))
        d.append(le16(bits))
        d.append(contentsOf: Array("data".utf8))
        d.append(le32(UInt32(clamping: dataBytes)))
        return d
    }

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

/// Chunk in (16-bit LE at the capture rate) → 16 kHz WAV on disk, plus the numbers the
/// keyboard needs to decide whether to upload at all (duration, peak level).
public final class CaptureAssembler {
    public static let outputRate = 16_000

    public let url: URL
    public let inputRate: Double
    /// Loudest per-chunk level (`PCMLevel` scale) seen so far.
    public private(set) var peakLevel: Float = 0
    /// Level of the most recent chunk.
    public private(set) var lastLevel: Float = 0
    public private(set) var chunkCount = 0
    private let resampler: StreamingResampler
    private let writer: WAVFileWriter
    private var finished = false

    public init(url: URL, inputRate: Double) throws {
        self.url = url
        self.inputRate = inputRate
        resampler = StreamingResampler(inputRate: inputRate, outputRate: Double(Self.outputRate))
        writer = try WAVFileWriter(url: url, sampleRate: Self.outputRate)
    }

    /// Seconds of 16 kHz audio written so far.
    public var duration: TimeInterval { Double(writer.frameCount) / Double(Self.outputRate) }

    /// Appends one chunk; returns its level (0...1).
    @discardableResult
    public func append(int16LittleEndian data: Data) throws -> Float {
        try append(samples: PCM16.floats(fromLittleEndian: data))
    }

    @discardableResult
    public func append(samples: [Float]) throws -> Float {
        guard !finished else { return 0 }
        let level = PCMLevel.level(rms: PCMLevel.rms(samples))
        lastLevel = level
        peakLevel = max(peakLevel, level)
        chunkCount += 1
        try writer.append(resampler.process(samples))
        return level
    }

    /// Flushes the resampler and finalizes the WAV header. Returns the file's duration.
    @discardableResult
    public func finish() throws -> TimeInterval {
        guard !finished else { return duration }
        finished = true
        try writer.append(resampler.flush())
        try writer.finish()
        return duration
    }

    /// Closes and deletes the file (cancel / discard).
    public func discard() {
        finished = true
        try? writer.finish()
        try? FileManager.default.removeItem(at: url)
    }
}
