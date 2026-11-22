import Foundation
import ScriberShared

/// Spoken language hint for a file. Default is the same as dictation (Chinese, with English
/// expected in between).
public enum TranscriptLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case zh, en, ja, ko, auto

    public var id: String { rawValue }

    /// ISO-639-1 code sent to the engine; nil lets the engine detect it.
    public var code: String? { self == .auto ? nil : rawValue }

    public var displayName: String {
        switch self {
        case .zh: "中文"
        case .en: "英文"
        case .ja: "日文"
        case .ko: "韓文"
        case .auto: "自動偵測"
        }
    }

    /// Simplified → Traditional (Taiwan) applies to Chinese text; Japanese kanji and Korean must not
    /// be converted.
    var convertsToTraditional: Bool { self == .zh || self == .auto || self == .en }
}

/// The small set of choices shown before a file starts.
public struct TranscriptionOptions: Codable, Equatable, Sendable {
    /// A `[mm:ss]` marker at the start of each paragraph.
    public var timestamps: Bool
    /// 說話者 1, 2… (engines with diarization only; needs the whole file in one request).
    public var speakers: Bool
    public var language: TranscriptLanguage

    public init(timestamps: Bool = true, speakers: Bool = false, language: TranscriptLanguage = .zh) {
        self.timestamps = timestamps; self.speakers = speakers; self.language = language
    }

    private static let defaultsKey = "transcription.options"

    /// Last options used (UserDefaults; not a contract setting).
    public static func load(_ defaults: UserDefaults = AppGroup.defaults) -> TranscriptionOptions {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(TranscriptionOptions.self, from: data) else { return .init() }
        return value
    }

    public func save(_ defaults: UserDefaults = AppGroup.defaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// One prepared piece of the file. Times are seconds from the start of the file.
public struct SegmentInfo: Codable, Equatable, Sendable, Identifiable {
    public var index: Int
    /// Start of this segment's audio, including any leading overlap.
    public var start: TimeInterval
    public var end: TimeInterval
    /// Seconds at the start that repeat the previous segment (hard cut), else 0.
    public var leadingOverlap: TimeInterval
    /// Seconds at the end that the next segment repeats (hard cut), else 0.
    public var trailingOverlap: TimeInterval
    /// File name inside the job's folder.
    public var fileName: String
    public var bytes: Int

    public var id: Int { index }
    public var duration: TimeInterval { end - start }
    /// The part of the file this segment is responsible for (overlap excluded).
    public var ownStart: TimeInterval { start + leadingOverlap }

    public init(index: Int, start: TimeInterval, end: TimeInterval, leadingOverlap: TimeInterval = 0,
                trailingOverlap: TimeInterval = 0, fileName: String, bytes: Int = 0) {
        self.index = index; self.start = start; self.end = end
        self.leadingOverlap = leadingOverlap; self.trailingOverlap = trailingOverlap
        self.fileName = fileName; self.bytes = bytes
    }
}

/// A paragraph of the finished transcript (post-processed text).
public struct TranscriptParagraph: Codable, Equatable, Sendable {
    /// Seconds from the start of the file; nil when the engine gave no timing for it.
    public var start: TimeInterval?
    public var end: TimeInterval?
    /// 1-based speaker label number.
    public var speaker: Int?
    public var text: String
    /// A stretch that could not be transcribed (failed segment); `text` is empty.
    public var isMissing: Bool

    public init(start: TimeInterval?, end: TimeInterval? = nil, speaker: Int? = nil, text: String, isMissing: Bool = false) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text; self.isMissing = isMissing
    }
}

/// A subtitle cue (only built from real engine timings).
public struct TranscriptCue: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: Int?
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, speaker: Int? = nil, text: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}

/// User-facing problems with the file itself. Messages are zh-Hant and never contain the file name.
public enum TranscriptionError: Error, LocalizedError, Equatable, Sendable {
    /// AVFoundation cannot open or decode it.
    case unreadable
    /// Opens, but there is no audio track (e.g. a silent screen recording).
    case noAudioTrack
    /// DRM-protected (e.g. purchased music or films).
    case protected
    /// Decoded to nothing.
    case empty
    /// The original file is gone (resuming an interrupted job).
    case sourceMissing
    /// Disk full or the work folder cannot be written.
    case storage
    /// The system stopped decoding (iOS app in the background); the job pauses and continues later.
    case interrupted

    public var errorDescription: String? {
        switch self {
        case .unreadable: "這個檔案打不開，可能不是音訊或影片，或格式不支援"
        case .noAudioTrack: "這個檔案裡沒有聲音"
        case .protected: "這個檔案有版權保護（DRM），無法讀取"
        case .empty: "這個檔案裡沒有可以辨識的聲音"
        case .sourceMissing: "找不到原始檔案，請重新加入"
        case .storage: "沒有足夠的空間暫存音訊，請清出一些空間再試"
        case .interrupted: "轉錄暫停了，回到 Scriber 會繼續"
        }
    }
}
