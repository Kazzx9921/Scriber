import Accelerate
import Foundation

/// How a long file is cut into pieces for the engines.
///
/// Size limit: the smallest documented upload limit is Groq's 25 MB (free tier; OpenAI's is the
/// same). A segment is at most `hardCapSeconds + overlapSeconds` long; even in the 16-bit WAV
/// fallback (32 000 bytes a second at 16 kHz mono) that is 19.3 MB, and as AAC (the normal case,
/// measured ≈ 45 kbit/s for speech) about 3.4 MB. ElevenLabs allows 5 GB / 15 hours.
public struct SegmentationPolicy: Codable, Equatable, Sendable {
    /// Aimed-for segment length. The file is divided into equal parts no longer than this, and each
    /// planned boundary is moved to the quietest moment near it.
    public var targetSeconds: TimeInterval = 300
    /// The quiet point is searched this far before and after each planned boundary.
    public var searchWindowSeconds: TimeInterval = 30
    /// No segment (excluding overlap) is ever longer than this.
    public var hardCapSeconds: TimeInterval = 600
    /// Audio repeated at the start of the next segment after a hard cut (no pause found), so a word
    /// cut in half is heard whole on one side. The assembler removes the duplicate text.
    public var overlapSeconds: TimeInterval = 2
    /// Length of the stretch whose energy is measured when looking for a pause.
    public var quietStretchSeconds: TimeInterval = 0.4
    /// Analysis frame.
    public var frameSeconds: TimeInterval = 0.02
    /// A stretch counts as a pause when its RMS is below this absolute level (≈ -50 dBFS)…
    public var quietFloorRMS: Float = 0.003
    /// …or below this fraction of the window's median frame RMS (pauses in noisy recordings).
    public var quietRelativeToMedian: Float = 0.3

    public init() {}

    public static let standard = SegmentationPolicy()

    /// Largest segment file this policy can produce as 16-bit WAV at `sampleRate`.
    public func worstCaseWAVBytes(sampleRate: Int = 16_000) -> Int64 {
        Int64(((hardCapSeconds + overlapSeconds) * Double(sampleRate)).rounded(.up)) * 2 + 44
    }

    /// Number of equal parts for `duration` seconds (at least 1).
    public func plannedCount(duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 1 }
        return max(1, Int((duration / targetSeconds).rounded(.up)))
    }
}

/// Receives the segments a `QuietPointSegmenter` cuts, sample by sample.
public protocol SegmentSink: AnyObject {
    /// A new segment starts at `startSample` (absolute, 16 kHz). The first `leadingOverlapSamples`
    /// repeat the end of the previous segment (hard cut).
    func beginSegment(index: Int, startSample: Int, leadingOverlapSamples: Int) throws
    func appendSamples(_ samples: ArraySlice<Float>) throws
    /// The segment ends at `endSample` (exclusive). `trailingOverlapSamples` > 0 when the next
    /// segment will repeat the last part of this one.
    func endSegment(index: Int, endSample: Int, trailingOverlapSamples: Int) throws
}

/// Where a resumed segmentation picks up: the next segment's index, its cut position and the
/// overlap it starts with. The audio source must start at `cutSample - leadingOverlapSamples`.
public struct SegmenterResumePoint: Codable, Equatable, Sendable {
    public var index: Int
    public var cutSample: Int
    public var leadingOverlapSamples: Int

    public init(index: Int, cutSample: Int, leadingOverlapSamples: Int) {
        self.index = index; self.cutSample = cutSample; self.leadingOverlapSamples = leadingOverlapSamples
    }

    public var sourceStartSample: Int { cutSample - leadingOverlapSamples }
}

/// Streams 16 kHz mono audio into segments cut at pauses.
///
/// Boundaries are planned at equal intervals (`SegmentationPolicy.plannedCount`); each is moved to
/// the quietest `quietStretchSeconds` stretch within ±`searchWindowSeconds` of the plan, preferring
/// stretches closer to the plan when several are about as quiet. If no stretch in the window is
/// quiet (continuous music, constant talk over noise), the cut is made exactly at the planned
/// boundary and the next segment starts `overlapSeconds` earlier.
///
/// Memory: only the audio not yet handed to the sink is kept, at most about
/// `2 × searchWindowSeconds + overlapSeconds` plus one input chunk (≈ 4 MB), whatever the file length.
public final class QuietPointSegmenter {
    public let policy: SegmentationPolicy
    public let sampleRate: Int
    /// nil: no boundaries at all (whole file in one segment).
    private let plannedCount: Int?
    private let plannedLength: Double
    private let sink: SegmentSink

    private var index: Int
    /// Cut position where the current segment's own audio begins (its overlap starts earlier).
    private var nominalStart: Int
    /// Planned boundary number of the next cut (1-based, absolute plan).
    private var boundaryNumber: Int
    private var pending: [Float] = []
    private var pendingStart: Int
    private var started = false
    private var finished = false
    private let firstOverlap: Int

    /// Largest number of samples held at once (for tests and diagnostics).
    public private(set) var peakBufferedSamples = 0
    /// Cuts made so far: (sample, wasHardCut).
    public private(set) var cuts: [(sample: Int, hard: Bool)] = []

    private var windowSamples: Int { Int(policy.searchWindowSeconds * Double(sampleRate)) }
    private var overlapSamples: Int { Int(policy.overlapSeconds * Double(sampleRate)) }
    private var frameSamples: Int { max(1, Int(policy.frameSeconds * Double(sampleRate))) }

    /// - Parameters:
    ///   - totalSamples: expected length of the stream (from the file's duration), nil if unknown.
    ///   - singleSegment: put everything in one segment (speaker labels need one request).
    ///   - resume: continue an interrupted segmentation (the stream must start at
    ///     `resume.sourceStartSample`).
    public init(policy: SegmentationPolicy = .standard, sampleRate: Int = 16_000, totalSamples: Int?,
                singleSegment: Bool = false, resume: SegmenterResumePoint? = nil, sink: SegmentSink) {
        self.policy = policy
        self.sampleRate = sampleRate
        self.sink = sink
        let target = policy.targetSeconds * Double(sampleRate)
        if singleSegment {
            plannedCount = nil
            plannedLength = .infinity
        } else if let totalSamples, totalSamples > 0 {
            let count = max(1, Int((Double(totalSamples) / target).rounded(.up)))
            plannedCount = count
            plannedLength = Double(totalSamples) / Double(count)
        } else {
            plannedCount = Int.max
            plannedLength = target
        }
        index = resume?.index ?? 0
        nominalStart = resume?.cutSample ?? 0
        firstOverlap = resume?.leadingOverlapSamples ?? 0
        pendingStart = resume?.sourceStartSample ?? 0
        // The next planned boundary after the resume point. A cut lies within ±window of its
        // planned boundary (window < half a part), so rounding finds which boundary it was.
        if plannedLength.isFinite, plannedLength > 0 {
            boundaryNumber = max(1, Int((Double(nominalStart) / plannedLength).rounded()) + 1)
        } else {
            boundaryNumber = 1
        }
    }

    public func push(_ samples: [Float]) throws {
        guard !finished else { return }
        pending.append(contentsOf: samples)
        peakBufferedSamples = max(peakBufferedSamples, pending.count)
        try process(final: false)
    }

    /// End of stream: closes the last segment (if any audio arrived).
    public func finish() throws {
        guard !finished else { return }
        try process(final: true)
        finished = true
    }

    // MARK: - Cutting

    private var pendingEnd: Int { pendingStart + pending.count }
    private var hardCapSamples: Int { Int(policy.hardCapSeconds * Double(sampleRate)) }
    /// Samples the current segment's sink has received end here.
    private var written = 0

    /// Absolute sample of the next boundary to cut at, nil if none.
    private func nextBoundary() -> Int? {
        guard let plannedCount, plannedLength.isFinite else { return nil }
        var boundary: Int
        if boundaryNumber < plannedCount {
            boundary = Int((Double(boundaryNumber) * plannedLength).rounded())
        } else {
            // Stream longer than expected (or unknown length): keep cutting at the target length.
            guard plannedCount == Int.max || pendingEnd > Int((Double(plannedCount) * plannedLength).rounded()) else {
                return nil
            }
            boundary = nominalStart + Int(policy.targetSeconds * Double(sampleRate))
        }
        // The search window must start after the segment has some audio, and end within the cap.
        boundary = max(boundary, nominalStart + windowSamples + frameSamples)
        return min(boundary, nominalStart + hardCapSamples - windowSamples)
    }

    private func process(final: Bool) throws {
        if !started {
            guard !pending.isEmpty || !final else { return }
            started = true
            written = pendingStart
            try sink.beginSegment(index: index, startSample: pendingStart, leadingOverlapSamples: firstOverlap)
        }
        while let boundary = nextBoundary(), pendingEnd >= boundary + windowSamples {
            let (cut, hard) = findCut(near: boundary)
            try emit(upTo: cut)
            let overlap = hard ? overlapSamples : 0
            try sink.endSegment(index: index, endSample: cut, trailingOverlapSamples: overlap)
            cuts.append((cut, hard))
            index += 1
            nominalStart = cut
            boundaryNumber += 1
            // The overlap is still buffered: nothing at or after (boundary - window - overlap) has
            // been released, and the cut is never before (boundary - window).
            written = cut - overlap
            try sink.beginSegment(index: index, startSample: written, leadingOverlapSamples: overlap)
            try emit(upTo: cut)
            release()
        }
        if final {
            try emit(upTo: pendingEnd)
            try sink.endSegment(index: index, endSample: pendingEnd, trailingOverlapSamples: 0)
            pending.removeAll()
            pendingStart = pendingEnd
            return
        }
        // Audio before the next search window certainly belongs to the current segment.
        let certain = nextBoundary().map { $0 - windowSamples } ?? pendingEnd
        try emit(upTo: min(certain, pendingEnd))
        release()
    }

    /// Sends buffered samples in [written, end) to the current segment.
    private func emit(upTo end: Int) throws {
        guard end > written else { return }
        let lo = written - pendingStart
        let hi = end - pendingStart
        precondition(lo >= 0 && hi <= pending.count, "segmenter released audio it still needed")
        try sink.appendSamples(pending[lo..<hi])
        written = end
    }

    /// Drops samples that are written and can no longer be part of a search window or an overlap.
    private func release() {
        let keepFrom = nextBoundary().map { $0 - windowSamples - overlapSamples } ?? written
        let before = min(written, keepFrom)
        let count = min(max(0, before - pendingStart), pending.count)
        guard count > 0 else { return }
        pending.removeFirst(count)
        pendingStart += count
    }

    /// The quietest stretch within ±window of `boundary`, or a hard cut at `boundary`.
    private func findCut(near boundary: Int) -> (Int, Bool) {
        let frame = frameSamples
        let hardCapCut = nominalStart + Int(policy.hardCapSeconds * Double(sampleRate))
        let lo = max(boundary - windowSamples, pendingStart, nominalStart + frame)
        let hi = min(boundary + windowSamples, pendingEnd, hardCapCut)
        let frames = (hi - lo) / frame
        let stretch = max(1, Int((policy.quietStretchSeconds / policy.frameSeconds).rounded()))
        guard frames >= stretch else { return (min(boundary, hardCapCut), true) }

        // Mean square per frame.
        var energy = [Float](repeating: 0, count: frames)
        pending.withUnsafeBufferPointer { buffer in
            for f in 0..<frames {
                var value: Float = 0
                vDSP_measqv(buffer.baseAddress! + (lo - pendingStart + f * frame), 1, &value, vDSP_Length(frame))
                energy[f] = value
            }
        }
        // Moving mean over `stretch` frames via prefix sums.
        var prefix = [Double](repeating: 0, count: frames + 1)
        for f in 0..<frames { prefix[f + 1] = prefix[f] + Double(energy[f]) }
        let sorted = energy.sorted()
        let medianRMS = sorted[sorted.count / 2].squareRoot()
        let threshold = max(policy.quietFloorRMS, policy.quietRelativeToMedian * medianRMS)

        var bestStart = -1
        var bestScore = Double.infinity
        var bestRMS: Float = .infinity
        for s in 0...(frames - stretch) {
            let meanSquare = (prefix[s + stretch] - prefix[s]) / Double(stretch)
            let rms = Float(meanSquare.squareRoot())
            let center = lo + (s * frame) + stretch * frame / 2
            let distance = Double(abs(center - boundary)) / Double(max(1, windowSamples))
            // Prefer the plan when stretches are about equally quiet; anything far quieter wins.
            let score = Double(rms) * (1 + 0.5 * distance) + 1e-7 * distance
            if score < bestScore {
                bestScore = score
                bestStart = s
                bestRMS = rms
            }
        }
        guard bestStart >= 0, bestRMS <= threshold else {
            return (min(boundary, hardCapCut), true)
        }
        let cut = lo + bestStart * frame + stretch * frame / 2
        return (cut, false)
    }
}
