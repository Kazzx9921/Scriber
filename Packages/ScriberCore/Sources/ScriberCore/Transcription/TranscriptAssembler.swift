import Foundation
import ScriberShared

/// The dictation output path without the LLM and without the chat-sized punctuation rule:
/// rule-based cleanup → personal-dictionary replacements → Traditional Chinese (Taiwan) with 台 →
/// punctuation/spacing normalization. Applied per paragraph and per subtitle cue.
///
/// Not applied to transcripts: the LLM polish (slow and costly on long text, and long outputs get
/// truncated) and `PunctuationStyler` (it is meant for short chat messages).
public struct TranscriptPostProcessor: Sendable {
    private let body: @Sendable (String) -> String

    public init(_ body: @escaping @Sendable (String) -> String) { self.body = body }

    public func callAsFunction(_ text: String) -> String { body(text) }

    /// Trims only (tests).
    public static let identity = TranscriptPostProcessor { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Snapshot of the user's settings and dictionary, taken once per job.
    public static func live(language: TranscriptLanguage, settings: AppSettings = .shared,
                            dictionary: DictionaryStore = .shared) -> TranscriptPostProcessor {
        make(language: language, entries: dictionary.snapshot(), forceTraditional: settings.forceTraditional,
             spaceBetweenCJKAndLatin: settings.spaceBetweenCJKAndLatin)
    }

    static func make(language: TranscriptLanguage, entries: [DictionaryEntry], forceTraditional: Bool,
                     spaceBetweenCJKAndLatin: Bool) -> TranscriptPostProcessor {
        let replacer = DictionaryReplacer(entries: entries)
        let convert = forceTraditional && language.convertsToTraditional
        return TranscriptPostProcessor { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            return DictationPipeline.outputStage(RuleBasedCleanup.clean(trimmed), replacements: replacer.apply(to:),
                                                 convertToTraditional: convert,
                                                 spaceBetweenCJKAndLatin: spaceBetweenCJKAndLatin)
        }
    }
}

/// One segment's share of the finished transcript.
public struct SegmentTranscript: Codable, Equatable, Sendable {
    public var paragraphs: [TranscriptParagraph]
    public var cues: [TranscriptCue]
    public var granularity: TimedText.Granularity

    public init(paragraphs: [TranscriptParagraph], cues: [TranscriptCue], granularity: TimedText.Granularity) {
        self.paragraphs = paragraphs; self.cues = cues; self.granularity = granularity
    }

    /// Placeholder for a segment that failed: its own time range, no text.
    public static func missing(_ segment: SegmentInfo) -> SegmentTranscript {
        SegmentTranscript(paragraphs: [TranscriptParagraph(start: segment.ownStart, end: segment.end, text: "", isMissing: true)],
                          cues: [], granularity: .none)
    }
}

/// Engine speaker ids ("speaker_0") → 說話者 1, 2… in order of first appearance.
public struct SpeakerMap: Codable, Equatable, Sendable {
    private var labels: [String: Int] = [:]
    public init() {}

    mutating func label(for id: String?) -> Int? {
        guard let id, !id.isEmpty else { return nil }
        if let known = labels[id] { return known }
        let next = labels.count + 1
        labels[id] = next
        return next
    }
}

/// Builds paragraphs and subtitle cues from engine output, segment by segment, in order.
public struct TranscriptAssembler: Sendable {
    public var postProcess: TranscriptPostProcessor
    /// Speaker labels requested and available (single-request mode).
    public var diarized: Bool

    /// A silence at least this long starts a new paragraph.
    public var paragraphPause: TimeInterval = 1.8
    /// After this long, a paragraph ends at the next sentence end.
    public var paragraphSoftSeconds: TimeInterval = 40
    /// …or after this many characters.
    public var paragraphSoftCharacters = 220
    /// A paragraph never runs longer than this without a break at the next small pause.
    public var paragraphHardSeconds: TimeInterval = 120

    public var cueMaxSeconds: TimeInterval = 6
    /// Display width: CJK characters count 1, others ½ (about two subtitle lines).
    public var cueMaxWidth: Double = 32
    public var cuePause: TimeInterval = 0.7

    public init(postProcess: TranscriptPostProcessor, diarized: Bool = false) {
        self.postProcess = postProcess
        self.diarized = diarized
    }

    /// - Parameters:
    ///   - previous / next: the neighbouring segments' raw results, needed when this segment
    ///     overlaps them (hard cuts) and the engine gave no word timings.
    public func process(segment: SegmentInfo, result: TimedText,
                        previous: TimedText?, next: TimedText?, speakers: inout SpeakerMap) -> SegmentTranscript {
        var units = result.units.map { unit -> TimedText.Unit in
            var unit = unit
            unit.start += segment.start
            unit.end += segment.start
            return unit
        }
        var text = result.text
        let granularity = result.granularity

        switch granularity {
        case .word:
            // Both segments heard the overlap; each keeps the words that start on its side of the
            // overlap's midpoint (well inside both recordings, so no word there is cut off).
            if segment.leadingOverlap > 0 {
                let cutoff = segment.start + segment.leadingOverlap / 2
                units.removeAll { $0.start < cutoff }
            }
            if segment.trailingOverlap > 0 {
                let cutoff = segment.end - segment.trailingOverlap / 2
                units.removeAll { $0.start >= cutoff }
            }
        case .segment, .none:
            var current = granularity == .segment ? units.map(\.text).joined() : text
            var dropFront = 0
            var keepCount = current.count
            if segment.leadingOverlap > 0, let previous, let splice = OverlapText.splice(previous: Self.spliceText(previous), next: current) {
                dropFront = splice.dropFromNext
            }
            if segment.trailingOverlap > 0, let next, let splice = OverlapText.splice(previous: current, next: Self.spliceText(next)) {
                keepCount = splice.keepOfPrevious
            }
            if dropFront > 0 || keepCount < current.count {
                if granularity == .segment {
                    units = Self.trimUnits(units, dropFront: dropFront, keep: keepCount)
                } else {
                    let end = max(dropFront, keepCount)
                    current = String(Array(current)[dropFront..<end])
                    text = current
                }
            }
        }

        if granularity == .none {
            return SegmentTranscript(paragraphs: textParagraphs(text, start: segment.ownStart), cues: [], granularity: .none)
        }
        var paragraphs: [TranscriptParagraph] = []
        for raw in groupParagraphs(units, speakers: &speakers) {
            let processed = postProcess(raw.text)
            guard !processed.isEmpty else { continue }
            paragraphs.append(TranscriptParagraph(start: raw.start, end: raw.end, speaker: raw.speaker, text: processed))
        }
        var cues: [TranscriptCue] = []
        var cueSpeakers = speakers
        for raw in groupCues(units, granularity: granularity, speakers: &cueSpeakers) {
            let processed = postProcess(raw.text)
            guard !processed.isEmpty else { continue }
            cues.append(TranscriptCue(start: raw.start, end: max(raw.end, raw.start + 0.3), speaker: raw.speaker, text: processed))
        }
        return SegmentTranscript(paragraphs: paragraphs, cues: cues, granularity: granularity)
    }

    // MARK: Paragraphs

    private struct Group {
        var start: TimeInterval
        var end: TimeInterval
        var speaker: Int?
        var text: String
    }

    private func groupParagraphs(_ units: [TimedText.Unit], speakers: inout SpeakerMap) -> [Group] {
        var groups: [Group] = []
        var current: Group?
        for unit in units {
            let speaker = diarized ? speakers.label(for: unit.speaker) : nil
            if let open = current {
                let gap = unit.start - open.end
                let length = open.end - open.start
                let ended = Self.endsSentence(open.text)
                let soft = ended && (length >= paragraphSoftSeconds || open.text.count >= paragraphSoftCharacters)
                let hard = length >= paragraphHardSeconds && (ended || gap >= 0.4) || length >= paragraphHardSeconds * 2
                if (diarized && speaker != open.speaker) || gap >= paragraphPause || soft || hard {
                    groups.append(open)
                    current = nil
                }
            }
            if var open = current {
                open.text += unit.text
                open.end = max(open.end, unit.end)
                current = open
            } else {
                current = Group(start: unit.start, end: unit.end, speaker: speaker, text: unit.text)
            }
        }
        if let current { groups.append(current) }
        return groups
    }

    /// No timings: sentences grouped into paragraphs of about `paragraphSoftCharacters`; only the
    /// first gets a time (the segment's start).
    private func textParagraphs(_ text: String, start: TimeInterval) -> [TranscriptParagraph] {
        var paragraphs: [TranscriptParagraph] = []
        var buffer = ""
        func flush() {
            let processed = postProcess(buffer)
            buffer = ""
            guard !processed.isEmpty else { return }
            paragraphs.append(TranscriptParagraph(start: paragraphs.isEmpty ? start : nil, text: processed))
        }
        for sentence in Self.sentences(text) {
            buffer += sentence
            if buffer.count >= paragraphSoftCharacters { flush() }
        }
        flush()
        return paragraphs
    }

    // MARK: Cues

    private func groupCues(_ units: [TimedText.Unit], granularity: TimedText.Granularity,
                           speakers: inout SpeakerMap) -> [Group] {
        if granularity == .segment {
            // Whisper segments are subtitle-sized already (the model was trained on subtitles).
            return units.map { Group(start: $0.start, end: $0.end, speaker: nil, text: $0.text) }
        }
        var groups: [Group] = []
        var current: Group?
        for unit in units {
            let speaker = diarized ? speakers.label(for: unit.speaker) : nil
            if let open = current {
                let gap = unit.start - open.end
                let length = unit.end - open.start
                let width = Self.displayWidth(open.text + unit.text)
                let ended = Self.endsSentence(open.text) && open.end - open.start >= 1
                if (diarized && speaker != open.speaker) || gap >= cuePause || length > cueMaxSeconds
                    || width > cueMaxWidth || ended {
                    groups.append(open)
                    current = nil
                }
            }
            if var open = current {
                open.text += unit.text
                open.end = max(open.end, unit.end)
                current = open
            } else {
                current = Group(start: unit.start, end: unit.end, speaker: speaker, text: unit.text)
            }
        }
        if let current { groups.append(current) }
        return groups
    }

    // MARK: Text helpers

    static func spliceText(_ result: TimedText) -> String {
        result.granularity == .segment ? result.units.map(\.text).joined() : result.text
    }

    private static let sentenceEnders: Set<Character> = ["。", "？", "！", ".", "?", "!", "…", "⋯"]

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace && $0 != "」" && $0 != "』" && $0 != "\"" && $0 != "”" }) else { return false }
        return sentenceEnders.contains(last)
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if sentenceEnders.contains(character) {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func displayWidth(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 1 : 0.5) }
    }

    /// Removes `dropFront` characters from the start and keeps characters up to `keep` (counted
    /// in the units' joined text), dropping units that end up empty.
    static func trimUnits(_ units: [TimedText.Unit], dropFront: Int, keep: Int) -> [TimedText.Unit] {
        var out: [TimedText.Unit] = []
        var offset = 0
        for unit in units {
            let count = unit.text.count
            let lo = max(dropFront - offset, 0)
            let hi = min(keep - offset, count)
            offset += count
            guard hi > lo else { continue }
            var trimmed = unit
            trimmed.text = String(Array(unit.text)[lo..<hi])
            if trimmed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            out.append(trimmed)
        }
        return out
    }
}

/// Finds the words two neighbouring segments both heard (the overlap after a hard cut) when the
/// engine gave no word timings, and where to splice: the previous segment keeps the text up to the
/// middle of the repeated part (at a word start for Latin text), the next one continues from there.
/// Comparison ignores case, spaces and punctuation. A match must be at least 3 CJK characters or 6
/// Latin letters/digits, end near the end of the previous text and start near the start of the
/// next one; otherwise nothing is removed (a duplicated word reads better than a lost sentence).
public enum OverlapText {
    public struct Splice: Equatable, Sendable {
        /// Characters of the previous text to keep.
        public var keepOfPrevious: Int
        /// Characters to drop from the start of the next text.
        public var dropFromNext: Int
    }

    static let window = 60
    static let slack = 14

    public static func splice(previous: String, next: String) -> Splice? {
        let a = Array(normalized(previous).suffix(window))
        let b = Array(normalized(next).prefix(window))
        guard !a.isEmpty, !b.isEmpty else { return nil }

        // Longest common substring, ending near a's end and starting near b's start.
        var best = (length: 0, endA: 0, endB: 0)
        var previousRow = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var row = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1].character == b[j - 1].character {
                row[j] = previousRow[j - 1] + 1
                let length = row[j]
                let startB = j - length
                if length > best.length, i >= a.count - slack, startB <= slack {
                    best = (length, i, j)
                }
            }
            previousRow = row
        }
        guard best.length > 0 else { return nil }
        let match = a[(best.endA - best.length)..<best.endA]
        let hasCJK = match.contains { $0.character.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? false }
        guard best.length >= (hasCJK ? 3 : 6) else { return nil }

        // Split in the middle of the match; for Latin text move to the nearest word start.
        let startA = best.endA - best.length
        let startB = best.endB - best.length
        var split = best.length / 2
        if !hasCJK {
            let nextChars = Array(next)
            let candidates = (1..<best.length).filter { k in
                let offset = b[startB + k].offset
                return offset > 0 && nextChars[offset - 1].isWhitespace
            }
            if let nearest = candidates.min(by: { abs($0 - split) < abs($1 - split) }) { split = nearest }
        }
        let keep = a[startA + split].offset
        let drop = b[startB + split].offset
        return Splice(keepOfPrevious: keep, dropFromNext: drop)
    }

    /// Lowercased letters and digits with their Character offsets in the original string.
    static func normalized(_ text: String) -> [(character: Character, offset: Int)] {
        var out: [(Character, Int)] = []
        for (offset, character) in text.enumerated() where character.isLetter || character.isNumber {
            out.append((Character(character.lowercased()), offset))
        }
        return out
    }
}
