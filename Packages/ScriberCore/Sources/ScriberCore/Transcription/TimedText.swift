import Foundation
import ScriberShared

// File transcription (轉錄): models shared by the engines, the scheduler and the assembler.
// Platform-neutral (Foundation only). Decoding/encoding with AVFoundation lives in
// `AudioIngest+AVFoundation.swift`.

/// What an engine returned for one piece of a file: the text and, where the engine provides it,
/// when each word (ElevenLabs Scribe) or phrase (Whisper `verbose_json` segments) was spoken.
public struct TimedText: Codable, Equatable, Sendable {
    public enum Granularity: String, Codable, Sendable, Comparable {
        /// Text only (custom OpenAI-compatible engines).
        case none
        /// Phrase timings (Whisper segments, typically a sentence or two).
        case segment
        /// Word timings (Scribe v3 `timestamps_granularity=word`).
        case word

        private var rank: Int { self == .none ? 0 : self == .segment ? 1 : 2 }
        public static func < (a: Granularity, b: Granularity) -> Bool { a.rank < b.rank }
    }

    /// A word or phrase. Times are seconds from the start of the audio the engine was sent.
    /// `text` carries its own leading whitespace, so joining the units gives back the text.
    public struct Unit: Codable, Equatable, Sendable {
        public var text: String
        public var start: TimeInterval
        public var end: TimeInterval
        /// Engine speaker id (e.g. "speaker_0") when diarization was requested.
        public var speaker: String?

        public init(text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil) {
            self.text = text; self.start = start; self.end = end; self.speaker = speaker
        }
    }

    public var text: String
    public var granularity: Granularity
    public var units: [Unit]

    public init(text: String, granularity: Granularity = .none, units: [Unit] = []) {
        self.text = text
        self.granularity = units.isEmpty ? .none : granularity
        self.units = units
    }

    public static let empty = TimedText(text: "")
}

/// What one engine can do with a file, from its documentation.
public struct FileTranscriptionCapabilities: Sendable, Equatable {
    /// Timing detail the engine returns (requested whenever available: it costs nothing extra and
    /// enables paragraph breaks at pauses, real timestamps and SRT).
    public var granularity: TimedText.Granularity
    /// Speaker labels (diarization).
    public var diarization: Bool
    /// Largest upload the engine documents.
    public var maxUploadBytes: Int64
    /// Longest audio one request may carry, when documented. Bounds the single-request mode used
    /// for speaker labels.
    public var maxRequestSeconds: TimeInterval?

    public init(granularity: TimedText.Granularity, diarization: Bool, maxUploadBytes: Int64,
                maxRequestSeconds: TimeInterval? = nil) {
        self.granularity = granularity; self.diarization = diarization
        self.maxUploadBytes = maxUploadBytes; self.maxRequestSeconds = maxRequestSeconds
    }

    /// ElevenLabs Scribe: "The file size must be less than 5.0GB", up to 15 hours of audio,
    /// diarization up to 32 speakers, word-level timestamps.
    /// https://elevenlabs.io/docs/api-reference/speech-to-text/convert
    /// https://elevenlabs.io/docs/overview/capabilities/speech-to-text
    public static let elevenLabs = FileTranscriptionCapabilities(
        granularity: .word, diarization: true, maxUploadBytes: 5_000_000_000, maxRequestSeconds: 15 * 3600)

    /// Groq Whisper: "Max File Size: 25 MB (free tier), 100MB (dev tier)"; `verbose_json` returns
    /// segment timings. The free-tier figure is used because the user's tier is unknown.
    /// https://console.groq.com/docs/speech-to-text
    public static let groq = FileTranscriptionCapabilities(
        granularity: .segment, diarization: false, maxUploadBytes: 25_000_000)

    /// User-defined OpenAI-compatible endpoint: OpenAI documents 25 MB; the response format is
    /// not known, so only plain text is requested.
    public static let custom = FileTranscriptionCapabilities(
        granularity: .none, diarization: false, maxUploadBytes: 25_000_000)
}

/// Per-request parameters for file transcription.
public struct FileSTTRequest: Sendable, Equatable {
    /// ISO-639-1 hint; nil = detect.
    public var languageCode: String?
    public var keyterms: [String]
    /// Ask for speaker labels (only honoured by engines that support it).
    public var diarize: Bool
    /// Seconds of audio in the file (used to size the timeout).
    public var audioSeconds: TimeInterval

    public init(languageCode: String?, keyterms: [String] = [], diarize: Bool = false, audioSeconds: TimeInterval) {
        self.languageCode = languageCode; self.keyterms = keyterms
        self.diarize = diarize; self.audioSeconds = audioSeconds
    }

    /// Upload plus processing allowance: generous, because a stuck request is retried anyway and a
    /// whole-file request (speaker labels) can legitimately take many minutes.
    public var timeout: TimeInterval {
        min(2 * 3600, 150 + audioSeconds * 0.5)
    }
}

/// An engine that transcribes one audio file (a segment, or a whole file in single-request mode).
public protocol FileTranscriber: Sendable {
    var engine: STTProviderKind { get }
    var capabilities: FileTranscriptionCapabilities { get }
    func transcribe(file: URL, request: FileSTTRequest) async throws -> TimedText
}

/// HTTP 429 from an engine, with the server's `Retry-After` when it sent one.
public struct RateLimitedError: Error, Sendable, Equatable {
    public var retryAfter: TimeInterval?
    public var message: String
    public init(retryAfter: TimeInterval?, message: String = "") {
        self.retryAfter = retryAfter; self.message = message
    }
}
