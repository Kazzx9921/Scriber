import Darwin
import XCTest
@testable import ScriberCore

/// Synthetic 16 kHz audio: deterministic noise ("speech") with silent stretches at known times.
struct SyntheticAudio {
    var seconds: Double
    /// Silent ranges in seconds.
    var silences: [ClosedRange<Double>] = []
    var speechAmplitude: Float = 0.3
    /// Level inside silences (0 = digital silence).
    var floorAmplitude: Float = 0

    var totalSamples: Int { Int(seconds * 16_000) }

    func sample(_ i: Int) -> Float {
        let t = Double(i) / 16_000
        // xorshift-style hash → -1...1
        var x = UInt32(truncatingIfNeeded: i &* 2_654_435_761)
        x ^= x << 13; x ^= x >> 17; x ^= x << 5
        let noise = Float(x % 20_001) / 10_000 - 1
        if silences.contains(where: { $0.contains(t) }) { return noise * floorAmplitude }
        return noise * speechAmplitude
    }

    func chunk(from start: Int, count: Int) -> [Float] {
        (start..<min(start + count, totalSamples)).map(sample)
    }
}

/// Records what the segmenter hands out.
final class RecordingSink: SegmentSink {
    struct Segment { var index: Int; var start: Int; var end: Int = 0; var leading: Int; var trailing = 0; var samples: [Float] = []; var count = 0 }
    var segments: [Segment] = []
    var keepSamples: Bool
    init(keepSamples: Bool = true) { self.keepSamples = keepSamples }

    func beginSegment(index: Int, startSample: Int, leadingOverlapSamples: Int) throws {
        segments.append(Segment(index: index, start: startSample, leading: leadingOverlapSamples))
    }
    func appendSamples(_ samples: ArraySlice<Float>) throws {
        segments[segments.count - 1].count += samples.count
        if keepSamples { segments[segments.count - 1].samples.append(contentsOf: samples) }
    }
    func endSegment(index: Int, endSample: Int, trailingOverlapSamples: Int) throws {
        segments[segments.count - 1].end = endSample
        segments[segments.count - 1].trailing = trailingOverlapSamples
    }
}

final class TranscriptionSegmenterTests: XCTestCase {
    private func run(_ audio: SyntheticAudio, policy: SegmentationPolicy, total: Int? = -1, chunk: Int = 4000,
                     sink: RecordingSink = RecordingSink(), single: Bool = false,
                     resume: SegmenterResumePoint? = nil) throws -> (RecordingSink, QuietPointSegmenter) {
        let segmenter = QuietPointSegmenter(policy: policy, totalSamples: total == -1 ? audio.totalSamples : total,
                                            singleSegment: single, resume: resume, sink: sink)
        var position = resume?.sourceStartSample ?? 0
        while position < audio.totalSamples {
            try segmenter.push(audio.chunk(from: position, count: chunk))
            position += chunk
        }
        try segmenter.finish()
        return (sink, segmenter)
    }

    private var smallPolicy: SegmentationPolicy {
        var policy = SegmentationPolicy()
        policy.targetSeconds = 20
        policy.searchWindowSeconds = 4
        policy.hardCapSeconds = 40
        policy.overlapSeconds = 1
        return policy
    }

    /// Cuts land inside the planted pauses, preferring the one nearest the plan.
    func testCutsLandInSilencesNearPlannedBoundaries() throws {
        // 960 s → 4 parts of 240 s; boundaries at 240, 480, 720.
        let audio = SyntheticAudio(seconds: 960, silences: [232...232.8, 260...260.8, 491...491.8, 705...705.8])
        let (sink, segmenter) = try run(audio, policy: .standard)
        XCTAssertEqual(sink.segments.count, 4)
        XCTAssertEqual(segmenter.cuts.map(\.hard), [false, false, false])
        let cuts = segmenter.cuts.map { Double($0.sample) / 16_000 }
        XCTAssertTrue((232...232.8).contains(cuts[0]), "cut 1 at \(cuts[0]) should be in the pause 8 s before the plan, not the one 20 s after")
        XCTAssertTrue((491...491.8).contains(cuts[1]), "cut 2 at \(cuts[1])")
        XCTAssertTrue((705...705.8).contains(cuts[2]), "cut 3 at \(cuts[2])")
        // Contiguous, no overlap, every sample once.
        for (a, b) in zip(sink.segments, sink.segments.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
            XCTAssertEqual(b.leading, 0)
            XCTAssertEqual(a.trailing, 0)
        }
        XCTAssertEqual(sink.segments.reduce(0) { $0 + $1.count }, audio.totalSamples)
        XCTAssertEqual(sink.segments.last?.end, audio.totalSamples)
        for segment in sink.segments { XCTAssertEqual(segment.count, segment.end - segment.start) }
    }

    /// No pause anywhere: hard cut exactly at the plan, the next segment repeats the overlap.
    func testHardCutWithOverlapWhenThereIsNoPause() throws {
        let policy = smallPolicy
        let audio = SyntheticAudio(seconds: 70) // 4 parts of 17.5 s
        let (sink, segmenter) = try run(audio, policy: policy)
        XCTAssertEqual(sink.segments.count, 4)
        XCTAssertEqual(segmenter.cuts.map(\.hard), [true, true, true])
        XCTAssertEqual(segmenter.cuts.map(\.sample), [280_000, 560_000, 840_000])
        let overlap = 16_000
        for (a, b) in zip(sink.segments, sink.segments.dropFirst()) {
            XCTAssertEqual(a.trailing, overlap)
            XCTAssertEqual(b.leading, overlap)
            XCTAssertEqual(b.start, a.end - overlap)
            XCTAssertEqual(Array(a.samples.suffix(overlap)), Array(b.samples.prefix(overlap)), "overlap audio must be identical")
        }
        // The audio itself is reproduced exactly.
        let first = sink.segments[0]
        XCTAssertEqual(first.samples, audio.chunk(from: 0, count: first.count))
        let second = sink.segments[1]
        XCTAssertEqual(second.samples, audio.chunk(from: second.start, count: second.count))
    }

    /// Two equally quiet pauses in the window: the one closer to the plan wins.
    func testPrefersThePauseNearestThePlan() throws {
        // 40 s → 2 parts, boundary at 20 s, window ±4 s.
        let audio = SyntheticAudio(seconds: 40, silences: [16.5...17.1, 21...21.6])
        let (_, segmenter) = try run(audio, policy: smallPolicy)
        XCTAssertEqual(segmenter.cuts.count, 1)
        let cut = Double(segmenter.cuts[0].sample) / 16_000
        XCTAssertFalse(segmenter.cuts[0].hard)
        XCTAssertTrue((21...21.6).contains(cut), "cut at \(cut)")
    }

    /// A pause 3 s from the plan is used rather than a hard cut at the plan.
    func testPauseAwayFromThePlanIsUsed() throws {
        var audio = SyntheticAudio(seconds: 40, silences: [17...17.6])
        audio.floorAmplitude = 0 // a real pause 3 s before the plan
        let (_, segmenter) = try run(audio, policy: smallPolicy)
        let cut = Double(segmenter.cuts[0].sample) / 16_000
        XCTAssertTrue((17...17.6).contains(cut), "cut at \(cut)")
    }

    /// Pauses in a noisy recording sit at the noise floor, not at digital silence.
    func testFindsPausesAboveTheAbsoluteFloorInNoisyAudio() throws {
        var audio = SyntheticAudio(seconds: 40, silences: [22...22.7])
        audio.floorAmplitude = 0.05 // ≈ -32 dBFS hiss: far above the -50 dBFS floor
        let (_, segmenter) = try run(audio, policy: smallPolicy)
        XCTAssertFalse(segmenter.cuts[0].hard)
        XCTAssertTrue((22...22.7).contains(Double(segmenter.cuts[0].sample) / 16_000))
    }

    func testSingleSegmentModeNeverCuts() throws {
        let audio = SyntheticAudio(seconds: 90, silences: [20...21, 40...41])
        let (sink, segmenter) = try run(audio, policy: smallPolicy, single: true)
        XCTAssertEqual(sink.segments.count, 1)
        XCTAssertTrue(segmenter.cuts.isEmpty)
        XCTAssertEqual(sink.segments[0].count, audio.totalSamples)
    }

    func testUnknownLengthCutsAtTheTarget() throws {
        let audio = SyntheticAudio(seconds: 50)
        let (sink, segmenter) = try run(audio, policy: smallPolicy, total: nil)
        XCTAssertEqual(segmenter.cuts.map(\.sample), [320_000, 640_000])
        XCTAssertEqual(sink.segments.count, 3)
    }

    func testShortFileIsOneSegment() throws {
        let audio = SyntheticAudio(seconds: 3)
        let (sink, _) = try run(audio, policy: .standard)
        XCTAssertEqual(sink.segments.count, 1)
        XCTAssertEqual(sink.segments[0].count, 48_000)
    }

    func testEmptyStreamMakesNoSegment() throws {
        let sink = RecordingSink()
        let segmenter = QuietPointSegmenter(totalSamples: 0, sink: sink)
        try segmenter.finish()
        XCTAssertTrue(sink.segments.isEmpty)
    }

    /// Resuming from a recorded cut produces the same remaining segments as an uninterrupted run.
    func testResumeContinuesWithTheSameCuts() throws {
        // 5 parts; the first cut is before its plan (19 s < 20 s), the last two are hard.
        let audio = SyntheticAudio(seconds: 100, silences: [19...19.5, 42...42.5])
        let (full, fullSegmenter) = try run(audio, policy: smallPolicy)
        XCTAssertGreaterThanOrEqual(fullSegmenter.cuts.count, 3)
        // Resume after each segment (its end and trailing overlap tell where the next one starts).
        for k in 0..<(full.segments.count - 1) {
            let after = full.segments[k]
            let resume = SegmenterResumePoint(index: k + 1, cutSample: after.end, leadingOverlapSamples: after.trailing)
            let (resumed, _) = try run(audio, policy: smallPolicy, resume: resume)
            let expected = Array(full.segments.dropFirst(k + 1))
            XCTAssertEqual(resumed.segments.map(\.index), expected.map(\.index), "resume after \(k)")
            XCTAssertEqual(resumed.segments.map(\.start), expected.map(\.start), "resume after \(k)")
            XCTAssertEqual(resumed.segments.map(\.end), expected.map(\.end), "resume after \(k)")
            XCTAssertEqual(resumed.segments.first?.samples, expected.first?.samples, "resume after \(k)")
        }
    }

    /// Every segment fits the smallest upload limit (Groq free tier 25 MB), even as WAV.
    func testWorstCaseSegmentFitsEveryProvider() {
        let policy = SegmentationPolicy.standard
        let worst = policy.worstCaseWAVBytes()
        XCTAssertLessThan(worst, FileTranscriptionCapabilities.groq.maxUploadBytes)
        XCTAssertLessThan(worst, FileTranscriptionCapabilities.custom.maxUploadBytes)
        XCTAssertLessThan(worst, FileTranscriptionCapabilities.elevenLabs.maxUploadBytes)
        // Planned parts plus the search window stay under the hard cap.
        XCTAssertLessThanOrEqual(policy.targetSeconds + 2 * policy.searchWindowSeconds, policy.hardCapSeconds)
    }

    /// A 3-hour stream generated on the fly: segment lengths stay within the cap, the buffer stays
    /// at about a minute of audio, and resident memory does not grow with the length.
    func testThreeHourStreamKeepsMemoryFlat() throws {
        let seconds = 3 * 3600
        let chunk = 8_000
        // Speech with a 0.6 s pause every 47 s, from two precomputed blocks.
        let speech = SyntheticAudio(seconds: 1).chunk(from: 0, count: chunk)
        let pause = [Float](repeating: 0, count: chunk)
        let sink = RecordingSink(keepSamples: false)
        let segmenter = QuietPointSegmenter(totalSamples: seconds * 16_000, sink: sink)
        let before = Self.residentBytes()
        var peakGrowth = 0
        let chunks = seconds * 16_000 / chunk
        for n in 0..<chunks {
            let t = Double(n * chunk) / 16_000
            let inPause = t.truncatingRemainder(dividingBy: 47) < 0.6
            try segmenter.push(inPause ? pause : speech)
            if n % 2000 == 0 { peakGrowth = max(peakGrowth, Self.residentBytes() - before) }
        }
        try segmenter.finish()
        peakGrowth = max(peakGrowth, Self.residentBytes() - before)

        XCTAssertEqual(sink.segments.count, 36)
        XCTAssertEqual(sink.segments.reduce(0) { $0 + $1.count } - sink.segments.reduce(0) { $0 + $1.leading },
                       seconds * 16_000)
        for segment in sink.segments {
            XCTAssertLessThanOrEqual(Double(segment.count) / 16_000, SegmentationPolicy.standard.hardCapSeconds + 2)
        }
        let bufferLimit = Int((2 * 30 + 2) * 16_000) + chunk
        XCTAssertLessThanOrEqual(segmenter.peakBufferedSamples, bufferLimit)
        // 3 h of Float32 would be 691 MB; the segmenter holds ≈ 4 MB.
        XCTAssertLessThan(peakGrowth, 48 * 1_048_576, "resident memory grew by \(peakGrowth / 1_048_576) MB")
        print("3h stream: segments=\(sink.segments.count) hardCuts=\(segmenter.cuts.filter(\.hard).count) peakBuffer=\(segmenter.peakBufferedSamples / 16_000)s rssGrowth=\(peakGrowth / 1_048_576)MB")
    }

    static func residentBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
