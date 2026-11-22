import Foundation
import ScriberShared

/// Time labels for transcripts.
public enum TranscriptTime {
    /// "05:07" (files under an hour) or "1:05:07" (`longForm`).
    public static func label(_ seconds: TimeInterval, longForm: Bool) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return longForm ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", h * 60 + m, s)
    }

    /// SRT timestamp "01:05:07,250".
    public static func srt(_ seconds: TimeInterval) -> String {
        let millis = max(0, Int((seconds * 1000).rounded()))
        let h = millis / 3_600_000, m = (millis / 60_000) % 60, s = (millis / 1000) % 60, ms = millis % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Length for lists: "42 秒", "12 分鐘", "1 小時 5 分".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) 分鐘" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) 小時" : "\(minutes / 60) 小時 \(rest) 分"
    }
}

/// A saved transcript.
public struct TranscriptRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var date: Date
    /// Seconds of audio in the file.
    public var duration: TimeInterval
    public var engine: STTProviderKind
    public var options: TranscriptionOptions
    /// Best timing the paragraphs carry (`.none`: only segment starts).
    public var granularity: TimedText.Granularity
    /// Speaker labels are present.
    public var hasSpeakers: Bool
    public var paragraphs: [TranscriptParagraph]
    /// Subtitle cues from real engine timings; empty when the engine gave none.
    public var cues: [TranscriptCue]
    /// Lowercased extension of the original file ("mp3", "mov").
    public var sourceExtension: String

    public init(id: UUID = UUID(), title: String, date: Date = Date(), duration: TimeInterval, engine: STTProviderKind,
                options: TranscriptionOptions, granularity: TimedText.Granularity, hasSpeakers: Bool,
                paragraphs: [TranscriptParagraph], cues: [TranscriptCue], sourceExtension: String) {
        self.id = id; self.title = title; self.date = date; self.duration = duration; self.engine = engine
        self.options = options; self.granularity = granularity; self.hasSpeakers = hasSpeakers
        self.paragraphs = paragraphs; self.cues = cues; self.sourceExtension = sourceExtension
    }

    public var missingCount: Int { paragraphs.filter(\.isMissing).count }
    /// SRT is offered only with real timings (see `TranscriptExport.srt`).
    public var canExportSRT: Bool { !cues.isEmpty }
    public var characterCount: Int { paragraphs.reduce(0) { $0 + $1.text.count } }
}

/// Plain text, Markdown and SRT.
///
/// SRT is only produced from real engine timings (Scribe word timings, Whisper phrase timings).
/// Engines without timings (custom) get no SRT: their only reference points are the segment
/// starts, minutes apart, and a "subtitle" that stays on screen for five minutes would be wrong
/// rather than approximate.
public enum TranscriptExport {
    public enum Format: String, CaseIterable, Sendable, Identifiable {
        case text, markdown, srt
        public var id: String { rawValue }
        public var fileExtension: String {
            switch self {
            case .text: "txt"
            case .markdown: "md"
            case .srt: "srt"
            }
        }
        public var displayName: String {
            switch self {
            case .text: "純文字（.txt）"
            case .markdown: "Markdown（.md）"
            case .srt: "字幕（.srt）"
            }
        }
    }

    public static let missingText = "這段沒有轉錄成功"

    public struct Style: Equatable, Sendable {
        public var timestamps: Bool
        public var speakers: Bool
        public init(timestamps: Bool, speakers: Bool) { self.timestamps = timestamps; self.speakers = speakers }
    }

    public static func style(for record: TranscriptRecord) -> Style {
        Style(timestamps: record.options.timestamps, speakers: record.options.speakers && record.hasSpeakers)
    }

    /// "[05:07] 說話者 1：…" lines separated by blank lines.
    public static func plainText(_ paragraphs: [TranscriptParagraph], style: Style, duration: TimeInterval) -> String {
        let longForm = duration >= 3600
        return paragraphs.map { paragraph in
            if paragraph.isMissing {
                return "（\(missingRange(paragraph, longForm: longForm))\(missingText)）"
            }
            var prefix = ""
            if style.timestamps, let start = paragraph.start { prefix += "[\(TranscriptTime.label(start, longForm: longForm))] " }
            if style.speakers, let speaker = paragraph.speaker { prefix += "說話者 \(speaker)：" }
            return prefix + paragraph.text
        }.joined(separator: "\n\n")
    }

    public static func markdown(_ record: TranscriptRecord, style: Style? = nil) -> String {
        let style = style ?? self.style(for: record)
        let longForm = record.duration >= 3600
        var lines = ["# \(record.title)", ""]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "yyyy/M/d HH:mm"
        lines.append("\(formatter.string(from: record.date))・\(TranscriptTime.duration(record.duration))")
        lines.append("")
        for paragraph in record.paragraphs {
            var head: [String] = []
            if style.timestamps, let start = paragraph.start { head.append("[\(TranscriptTime.label(start, longForm: longForm))]") }
            if paragraph.isMissing {
                lines.append("*（\(missingRange(paragraph, longForm: longForm))\(missingText)）*")
            } else {
                if style.speakers, let speaker = paragraph.speaker { head.append("說話者 \(speaker)：") }
                let lead = head.isEmpty ? "" : "**\(head.joined(separator: " "))** "
                lines.append(lead + paragraph.text)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// nil when the record has no real timings.
    public static func srt(_ record: TranscriptRecord, style: Style? = nil) -> String? {
        guard record.canExportSRT else { return nil }
        let style = style ?? self.style(for: record)
        var blocks: [String] = []
        for (index, cue) in record.cues.enumerated() {
            var text = cue.text
            if style.speakers, let speaker = cue.speaker { text = "說話者 \(speaker)：" + text }
            blocks.append("\(index + 1)\n\(TranscriptTime.srt(cue.start)) --> \(TranscriptTime.srt(cue.end))\n\(text)")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    public static func render(_ record: TranscriptRecord, as format: Format, style: Style? = nil) -> String? {
        let style = style ?? self.style(for: record)
        switch format {
        case .text: return plainText(record.paragraphs, style: style, duration: record.duration)
        case .markdown: return markdown(record, style: style)
        case .srt: return srt(record, style: style)
        }
    }

    /// Writes the export to a temporary file named after the transcript (for sharing / saving).
    public static func temporaryFile(_ record: TranscriptRecord, as format: Format, style: Style? = nil) throws -> URL {
        guard let text = render(record, as: format, style: style) else { throw CocoaError(.featureUnsupported) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberExport-\(UUID().uuidString.prefix(8))",
                                                                                   isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(safeFileName(record.title)).appendingPathExtension(format.fileExtension)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static func safeFileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "逐字稿" : String(cleaned.prefix(80))
    }

    private static func missingRange(_ paragraph: TranscriptParagraph, longForm: Bool) -> String {
        guard let start = paragraph.start, let end = paragraph.end else { return "" }
        return "\(TranscriptTime.label(start, longForm: longForm))–\(TranscriptTime.label(end, longForm: longForm)) "
    }
}
