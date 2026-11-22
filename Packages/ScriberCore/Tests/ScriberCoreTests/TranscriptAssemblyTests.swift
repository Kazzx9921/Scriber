import XCTest
@testable import ScriberCore
import ScriberShared

final class TranscriptAssemblyTests: XCTestCase {
    private func words(_ items: [(String, Double)], speaker: String? = nil, length: Double = 0.3) -> [TimedText.Unit] {
        items.map { TimedText.Unit(text: $0.0, start: $0.1, end: $0.1 + length, speaker: speaker) }
    }

    // MARK: Overlap, word timings

    /// After a hard cut at 300 s with 2 s overlap, both segments heard 298–300 s; each keeps the
    /// words starting on its side of 299 s, so nothing repeats and nothing is lost.
    func testWordTimingsRemoveTheOverlapAtItsMidpoint() {
        let first = SegmentInfo(index: 0, start: 0, end: 300, trailingOverlap: 2, fileName: "a")
        let second = SegmentInfo(index: 1, start: 298, end: 400, leadingOverlap: 2, fileName: "b")
        // Segment 0 (times relative to 0): "… 我們 明天 再 見"; the last word is cut off at 300 s.
        let a = TimedText(text: "", granularity: .word,
                          units: words([("我們", 297.0), ("明天", 298.2), ("再", 299.1), ("見", 299.8)]))
        // Segment 1 (relative to 298 s): heard from 298 s: "明天 再 見 大家 好".
        let b = TimedText(text: "", granularity: .word,
                          units: words([("明天", 0.2), ("再", 1.1), ("見", 1.8), ("大家", 2.5), ("好", 3.0)]))
        let assembler = TranscriptAssembler(postProcess: .identity)
        var speakers = SpeakerMap()
        let p0 = assembler.process(segment: first, result: a, previous: nil, next: b, speakers: &speakers)
        let p1 = assembler.process(segment: second, result: b, previous: a, next: nil, speakers: &speakers)
        let text = (p0.paragraphs + p1.paragraphs).map(\.text).joined()
        XCTAssertEqual(text, "我們明天再見大家好")
        XCTAssertEqual(p1.paragraphs.first?.start ?? -1, 299.1, accuracy: 0.001, "absolute time of the first kept word")
    }

    // MARK: Overlap, text only

    func testSpliceChineseOverlap() throws {
        let previous = "今天的會議先到這裡，我們明天下午再"
        let next = "明天下午再討論預算，大家辛苦了"
        let splice = try XCTUnwrap(OverlapText.splice(previous: previous, next: next))
        let joined = String(previous.prefix(splice.keepOfPrevious)) + String(next.dropFirst(splice.dropFromNext))
        XCTAssertEqual(joined, "今天的會議先到這裡，我們明天下午再討論預算，大家辛苦了")
    }

    func testSpliceLatinOverlapAtAWordStart() throws {
        // The previous segment's last word is cut off ("sto"); the next starts mid-word ("ing").
        let previous = "We are going to the sto"
        let next = "ing to the store and buy some milk."
        let splice = try XCTUnwrap(OverlapText.splice(previous: previous, next: next))
        let joined = String(previous.prefix(splice.keepOfPrevious)) + String(next.dropFirst(splice.dropFromNext))
        XCTAssertEqual(joined, "We are going to the store and buy some milk.")
    }

    func testSpliceIgnoresPunctuationAndCase() throws {
        let previous = "Thanks everyone. See you Tuesday,"
        let next = "see you tuesday, at ten."
        let splice = try XCTUnwrap(OverlapText.splice(previous: previous, next: next))
        let joined = String(previous.prefix(splice.keepOfPrevious)) + String(next.dropFirst(splice.dropFromNext))
        XCTAssertEqual(joined, "Thanks everyone. See you tuesday, at ten.")
    }

    func testNoSpliceWithoutARealMatch() {
        XCTAssertNil(OverlapText.splice(previous: "我們明天見", next: "大家好今天天氣很好"))
        // A short accidental match ("the") is not enough for Latin text.
        XCTAssertNil(OverlapText.splice(previous: "we saw the", next: "the end of it"))
        // A match far from the joint does not count.
        XCTAssertNil(OverlapText.splice(previous: "預算討論" + String(repeating: "後面還有很多很多別的話", count: 3),
                                        next: "預算討論然後"))
    }

    func testTextOnlySegmentsAreSplicedBothWays() {
        let first = SegmentInfo(index: 0, start: 0, end: 300, trailingOverlap: 2, fileName: "a")
        let second = SegmentInfo(index: 1, start: 298, end: 500, leadingOverlap: 2, fileName: "b")
        let a = TimedText(text: "第一段的內容，最後說到明天下午再")
        let b = TimedText(text: "明天下午再討論。第二段繼續。")
        let assembler = TranscriptAssembler(postProcess: .identity)
        var speakers = SpeakerMap()
        let p0 = assembler.process(segment: first, result: a, previous: nil, next: b, speakers: &speakers)
        let p1 = assembler.process(segment: second, result: b, previous: a, next: nil, speakers: &speakers)
        XCTAssertEqual((p0.paragraphs + p1.paragraphs).map(\.text).joined(), "第一段的內容，最後說到明天下午再討論。第二段繼續。")
        XCTAssertEqual(p0.paragraphs.first?.start, 0)
        XCTAssertEqual(p1.paragraphs.first?.start, 300, "text-only paragraphs start at the segment's own start")
        XCTAssertTrue(p0.cues.isEmpty, "no SRT cues without engine timings")
    }

    func testWhisperSegmentsAreSplicedAcrossUnits() {
        let first = SegmentInfo(index: 0, start: 0, end: 300, trailingOverlap: 2, fileName: "a")
        let second = SegmentInfo(index: 1, start: 298, end: 400, leadingOverlap: 2, fileName: "b")
        let a = TimedText(text: "", granularity: .segment, units: [
            .init(text: "我們先看第一個問題。", start: 280, end: 290),
            .init(text: "接下來討論明天下午再", start: 290, end: 300),
        ])
        let b = TimedText(text: "", granularity: .segment, units: [
            .init(text: "明天下午再開會。", start: 0, end: 3),
            .init(text: "散會。", start: 4, end: 5),
        ])
        let assembler = TranscriptAssembler(postProcess: .identity)
        var speakers = SpeakerMap()
        let p0 = assembler.process(segment: first, result: a, previous: nil, next: b, speakers: &speakers)
        let p1 = assembler.process(segment: second, result: b, previous: a, next: nil, speakers: &speakers)
        let all = (p0.paragraphs + p1.paragraphs).map(\.text).joined()
        XCTAssertEqual(all, "我們先看第一個問題。接下來討論明天下午再開會。散會。")
        XCTAssertEqual(p1.cues.first?.start ?? -1, 298, accuracy: 0.001)
    }

    // MARK: Paragraphs and speakers

    func testParagraphBreaksAtLongPausesAndSpeakerChanges() {
        let segment = SegmentInfo(index: 0, start: 0, end: 60, fileName: "a")
        var units = words([("大家好，", 0), ("今天", 0.5), ("開會。", 1.0)], speaker: "speaker_0")
        units += words([("好的", 1.6), ("沒問題。", 2.0)], speaker: "speaker_1")
        units += words([("那", 6.0), ("開始吧。", 6.4)], speaker: "speaker_1") // 3.7 s pause
        units += words([("謝謝。", 7.2)], speaker: "speaker_0")
        let assembler = TranscriptAssembler(postProcess: .identity, diarized: true)
        var speakers = SpeakerMap()
        let result = assembler.process(segment: segment, result: TimedText(text: "", granularity: .word, units: units),
                                       previous: nil, next: nil, speakers: &speakers)
        XCTAssertEqual(result.paragraphs.map(\.text), ["大家好，今天開會。", "好的沒問題。", "那開始吧。", "謝謝。"])
        XCTAssertEqual(result.paragraphs.map(\.speaker), [1, 2, 2, 1])
        XCTAssertEqual(result.paragraphs.map { $0.start ?? -1 }, [0, 1.6, 6.0, 7.2])
        // Cues split at speaker changes too.
        XCTAssertEqual(result.cues.map(\.speaker), [1, 2, 2, 1])
    }

    func testLongMonologueIsSplitAtSentenceEnds() {
        let segment = SegmentInfo(index: 0, start: 0, end: 200, fileName: "a")
        // One sentence every 5 s for 150 s, no pauses.
        let units = (0..<30).map { TimedText.Unit(text: "這是第\($0)句話。", start: Double($0) * 5, end: Double($0) * 5 + 4.9) }
        let assembler = TranscriptAssembler(postProcess: .identity)
        var speakers = SpeakerMap()
        let result = assembler.process(segment: segment, result: TimedText(text: "", granularity: .word, units: units),
                                       previous: nil, next: nil, speakers: &speakers)
        XCTAssertGreaterThan(result.paragraphs.count, 2)
        for paragraph in result.paragraphs {
            XCTAssertTrue(paragraph.text.hasSuffix("。"))
            XCTAssertLessThanOrEqual((paragraph.end ?? 0) - (paragraph.start ?? 0), 50)
        }
        XCTAssertTrue(result.cues.allSatisfy { $0.end - $0.start <= 6 })
    }

    func testTextOnlyResultIsSplitIntoParagraphs() {
        let segment = SegmentInfo(index: 3, start: 900, end: 1200, fileName: "a")
        let text = String(repeating: "這是一個比較長的句子，用來測試段落。", count: 30)
        let assembler = TranscriptAssembler(postProcess: .identity)
        var speakers = SpeakerMap()
        let result = assembler.process(segment: segment, result: TimedText(text: text), previous: nil, next: nil, speakers: &speakers)
        XCTAssertGreaterThan(result.paragraphs.count, 1)
        XCTAssertEqual(result.paragraphs.first?.start, 900)
        XCTAssertTrue(result.paragraphs.dropFirst().allSatisfy { $0.start == nil })
        XCTAssertEqual(result.paragraphs.map(\.text).joined(), text)
    }

    // MARK: Post-processing

    /// Same output stage as dictation (cleanup, dictionary, zh-TW + 台, normalization), but no
    /// chat punctuation rule: a short line keeps its final period.
    func testPostProcessorMatchesDictationOutputStage() {
        let processor = TranscriptPostProcessor.make(
            language: .zh, entries: [DictionaryEntry(term: "Claude Code", soundsLike: ["cloud code"])],
            forceTraditional: true, spaceBetweenCJKAndLatin: true)
        XCTAssertEqual(processor("嗯，我们用cloud code在台湾写软件。"), "我們用 Claude Code 在台灣寫軟體。")
        XCTAssertEqual(processor("好。"), "好。", "the short-text punctuation rule is not applied")
        let japanese = TranscriptPostProcessor.make(language: .ja, entries: [], forceTraditional: true,
                                                    spaceBetweenCJKAndLatin: true)
        XCTAssertEqual(japanese("会议"), "会议", "Japanese/Korean text is not converted to Traditional Chinese")
    }
}

final class TranscriptExportTests: XCTestCase {
    func testTimeLabels() {
        XCTAssertEqual(TranscriptTime.label(0, longForm: false), "00:00")
        XCTAssertEqual(TranscriptTime.label(307.9, longForm: false), "05:07")
        XCTAssertEqual(TranscriptTime.label(3599, longForm: false), "59:59")
        XCTAssertEqual(TranscriptTime.label(3907, longForm: true), "1:05:07")
        XCTAssertEqual(TranscriptTime.label(307, longForm: true), "0:05:07")
        XCTAssertEqual(TranscriptTime.srt(3907.25), "01:05:07,250")
        XCTAssertEqual(TranscriptTime.srt(0.0004), "00:00:00,000")
        XCTAssertEqual(TranscriptTime.srt(59.9996), "00:01:00,000")
        XCTAssertEqual(TranscriptTime.duration(42), "42 秒")
        XCTAssertEqual(TranscriptTime.duration(12 * 60 + 10), "12 分鐘")
        XCTAssertEqual(TranscriptTime.duration(3600 + 5 * 60), "1 小時 5 分")
        XCTAssertEqual(TranscriptTime.duration(7200), "2 小時")
    }

    private func record(cues: [TranscriptCue] = [], speakers: Bool = false, duration: TimeInterval = 400) -> TranscriptRecord {
        TranscriptRecord(
            title: "週會/錄音", date: Date(timeIntervalSince1970: 1_790_000_000), duration: duration, engine: .elevenLabsScribe,
            options: TranscriptionOptions(timestamps: true, speakers: speakers),
            granularity: cues.isEmpty ? .none : .word, hasSpeakers: speakers,
            paragraphs: [
                TranscriptParagraph(start: 0, end: 10, speaker: speakers ? 1 : nil, text: "大家好。"),
                TranscriptParagraph(start: 300, end: 420, text: "", isMissing: true),
                TranscriptParagraph(start: 425.4, end: 430, speaker: speakers ? 2 : nil, text: "我們繼續。"),
            ],
            cues: cues, sourceExtension: "m4a")
    }

    func testPlainText() {
        let record = record(speakers: true)
        let text = TranscriptExport.plainText(record.paragraphs, style: .init(timestamps: true, speakers: true), duration: 400)
        XCTAssertEqual(text, "[00:00] 說話者 1：大家好。\n\n（05:00–07:00 這段沒有轉錄成功）\n\n[07:05] 說話者 2：我們繼續。")
        let bare = TranscriptExport.plainText(record.paragraphs, style: .init(timestamps: false, speakers: false), duration: 400)
        XCTAssertEqual(bare, "大家好。\n\n（05:00–07:00 這段沒有轉錄成功）\n\n我們繼續。")
        let long = TranscriptExport.plainText([TranscriptParagraph(start: 3725, text: "後半。")],
                                              style: .init(timestamps: true, speakers: false), duration: 4000)
        XCTAssertEqual(long, "[1:02:05] 後半。")
    }

    func testMarkdown() {
        let markdown = TranscriptExport.markdown(record(speakers: true))
        let lines = markdown.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "# 週會/錄音")
        XCTAssertTrue(lines.contains("**[00:00] 說話者 1：** 大家好。"))
        XCTAssertTrue(lines.contains("*（05:00–07:00 這段沒有轉錄成功）*"))
        XCTAssertTrue(lines.contains("**[07:05] 說話者 2：** 我們繼續。"))
        XCTAssertTrue(lines[2].hasSuffix("・6 分鐘"))
    }

    func testSRTOnlyWithRealTimings() throws {
        XCTAssertNil(TranscriptExport.srt(record()))
        let cues = [TranscriptCue(start: 0.5, end: 2.25, speaker: 1, text: "大家好。"),
                    TranscriptCue(start: 3725.1, end: 3727, speaker: 2, text: "我們繼續。")]
        let srt = try XCTUnwrap(TranscriptExport.srt(record(cues: cues, speakers: true)))
        XCTAssertEqual(srt, """
        1
        00:00:00,500 --> 00:00:02,250
        說話者 1：大家好。

        2
        01:02:05,100 --> 01:02:07,000
        說話者 2：我們繼續。

        """)
    }

    func testExportFileNameIsSafe() throws {
        let url = try TranscriptExport.temporaryFile(record(), as: .markdown)
        XCTAssertEqual(url.lastPathComponent, "週會-錄音.md")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("# 週會/錄音"))
        XCTAssertThrowsError(try TranscriptExport.temporaryFile(record(), as: .srt))
    }
}
