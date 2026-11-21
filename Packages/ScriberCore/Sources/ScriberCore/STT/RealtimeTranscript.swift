import Foundation

/// The transcript of one real-time session, assembled from partial and committed events.
///
/// Semantics (event reference + live capture 2026-11-22): a `partial_transcript` replaces the
/// previous partial of the in-progress segment; a `committed_transcript` is the final text of that
/// segment, after which the partial starts over. A partial for the segment being committed can still
/// arrive between our commit and its `committed_transcript`; it is replaced when the commit lands.
public struct RealtimeTranscript: Equatable, Sendable {
    /// Final text of each committed segment, trimmed, in order. Empty commits are not stored.
    public private(set) var segments: [String] = []
    /// Interim text of the segment in progress (trimmed).
    public private(set) var partial = ""
    /// Commits received, including empty ones.
    public private(set) var commitCount = 0

    public init() {}

    public mutating func applyPartial(_ text: String) {
        partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func applyCommitted(_ text: String) {
        commitCount += 1
        partial = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { segments.append(trimmed) }
    }

    /// Everything committed so far: the text the pipeline post-processes.
    public var finalText: String { Self.join(segments) }

    /// Committed text plus the partial: what is on screen while speaking.
    public var displayText: String { Self.join(segments + (partial.isEmpty ? [] : [partial])) }

    /// Joins segments the way they were spoken: CJK runs touch directly (no space is ever inserted
    /// next to a CJK character or CJK punctuation; `ZhTW.normalize` decides CJK–Latin spacing later),
    /// Latin text gets one space between segments.
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts where !part.isEmpty {
            if let last = out.unicodeScalars.last, let first = part.unicodeScalars.first,
               needsSpace(between: last, and: first) {
                out += " "
            }
            out += part
        }
        return out
    }

    static func needsSpace(between left: Unicode.Scalar, and right: Unicode.Scalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(left) || CharacterSet.whitespacesAndNewlines.contains(right) {
            return false
        }
        return !isWide(left) && !isWide(right)
    }

    /// CJK ideographs, kana, hangul, CJK and full-width punctuation.
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }
}

/// When to commit while the user is still speaking, and what to do at stop. Pure, so the rules are
/// unit-tested.
///
/// - The server auto-commits after ~36 s of uncommitted audio (commit guide; live-verified), which
///   would break the one-commit-one-answer bookkeeping and cut mid-word, and the guide recommends
///   committing every 20–30 s. So: after `commitAfter` seconds, commit at the next quiet chunk;
///   at `forceAfter` seconds commit regardless.
/// - Never commit with less than 0.3 s of uncommitted audio (server closes the session).
/// - A segment of pure silence can come back as a hallucinated filler ("嗯。", live capture), so a
///   silent tail with no partial text is not committed at stop.
struct RealtimeCommitPlanner: Equatable, Sendable {
    var commitAfter: Double = 20
    var forceAfter: Double = 30
    /// `PCMLevel` scale. A chunk below this counts as a pause (speech sits around 0.4–0.8).
    var quietLevel: Float = 0.25
    /// Same threshold as `ClipPolicy.silenceLevel`: below it the audio holds no speech.
    var silenceLevel: Float = 0.12

    private(set) var uncommittedBytes = 0
    private(set) var uncommittedPeak: Float = 0

    var uncommittedSeconds: Double { Double(uncommittedBytes) / Double(RealtimeSTTWire.bytesPerSecond) }

    enum FinalAction: Equatable {
        /// Nothing uncommitted (or only silence): the transcript is complete once pending commits land.
        case none
        case commit
        /// Too little audio for a commit: send this many bytes of silence first.
        case padThenCommit(bytes: Int)
    }

    /// Records a chunk that was sent; true if a commit should follow it now.
    mutating func didSend(bytes: Int, level: Float) -> Bool {
        uncommittedBytes += bytes
        uncommittedPeak = max(uncommittedPeak, level)
        guard uncommittedBytes >= RealtimeSTTWire.minimumCommitBytes else { return false }
        if uncommittedSeconds >= forceAfter { return true }
        return uncommittedSeconds >= commitAfter && level < quietLevel && uncommittedPeak >= silenceLevel
    }

    mutating func didCommit() {
        uncommittedBytes = 0
        uncommittedPeak = 0
    }

    func finalAction(partialIsEmpty: Bool) -> FinalAction {
        guard uncommittedBytes > 0 else { return .none }
        if uncommittedPeak < silenceLevel, partialIsEmpty { return .none }
        if uncommittedBytes < RealtimeSTTWire.minimumCommitBytes {
            return .padThenCommit(bytes: RealtimeSTTWire.minimumCommitBytes - uncommittedBytes)
        }
        return .commit
    }
}

/// The live text the HUD shows: committed segments and the current partial, converted to
/// Traditional Chinese (Taiwan) with 台 — the cheap, deterministic part of the pipeline — so
/// Simplified characters never scroll by (Scribe returns Simplified for Mandarin, live capture).
///
/// Each committed segment is converted once and cached; only the partial (at most ~30 s of speech,
/// a few hundred characters) is converted per update. Not thread-safe: use from one thread.
public final class RealtimeLiveText {
    public let forceTraditional: Bool
    private var transcript = RealtimeTranscript()
    private var convertedSegments: [String] = []
    private var convertedCommitted = ""
    public private(set) var committed = ""
    public private(set) var partial = ""

    public init(forceTraditional: Bool) {
        self.forceTraditional = forceTraditional
    }

    /// Applies an event; true if the visible text changed.
    @discardableResult
    public func apply(_ event: RealtimeSTTEvent) -> Bool {
        let before = (committed, partial)
        switch event {
        case .partial(let text):
            transcript.applyPartial(text)
        case .committed(let text):
            transcript.applyCommitted(text)
            if transcript.segments.count > convertedSegments.count, let last = transcript.segments.last {
                convertedSegments.append(convert(last))
                convertedCommitted = RealtimeTranscript.join(convertedSegments)
            }
        case .started, .error, .closed:
            return false
        }
        committed = convertedCommitted
        partial = convert(transcript.partial)
        return before != (committed, partial)
    }

    public var isEmpty: Bool { committed.isEmpty && partial.isEmpty }

    /// The end of the text, for a view that shows only the last line or two.
    ///
    /// The committed part starts at a segment boundary and holds at most about
    /// `maxCommittedCharacters` (if the last segment alone is longer, its fixed-length end). It only
    /// changes when a segment is committed, so between commits the line breaks of what is on screen
    /// stay put and only the partial at the end moves: cutting at a sliding character index would
    /// re-wrap every line on each partial. The partial part is the whole partial (≤ ~30 s of speech,
    /// see `RealtimeCommitPlanner`), prefixed with the space the join would insert, if any.
    public func tail(maxCommittedCharacters limit: Int) -> (committed: String, partial: String) {
        var kept: [String] = []
        var length = 0
        for segment in convertedSegments.reversed() {
            guard length + segment.count <= limit else { break }
            kept.insert(segment, at: 0)
            length += segment.count
        }
        if kept.isEmpty, let last = convertedSegments.last {
            kept = [String(last.suffix(limit))]
        }
        let committedTail = RealtimeTranscript.join(kept)
        var partialPart = partial
        if !committedTail.isEmpty, !partial.isEmpty,
           let last = committedTail.unicodeScalars.last, let first = partial.unicodeScalars.first,
           RealtimeTranscript.needsSpace(between: last, and: first) {
            partialPart = " " + partial
        }
        return (committedTail, partialPart)
    }

    private func convert(_ text: String) -> String {
        guard forceTraditional, !text.isEmpty else { return text }
        return DictationPipeline.livePreview(text)
    }
}
