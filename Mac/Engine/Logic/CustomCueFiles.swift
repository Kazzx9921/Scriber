import AVFoundation
import Foundation
import ScriberShared

/// The user's own cue sounds: checked, then copied into Application Support (`AppGroup.containerURL`,
/// i.e. ~/Library/Application Support/Scriber/Sounds) so they keep working if the original moves.
struct CustomCueFiles {
    /// Above this the file is accepted with a warning (a cue should be a blip).
    static let warnSeconds: TimeInterval = 2
    /// Above this the file is refused.
    static let maxSeconds: TimeInterval = 5
    /// Larger files are refused before decoding (a 5 s cue is far below this in any format).
    static let maxBytes = 10_000_000

    enum Check: Equatable {
        case ok(TimeInterval)
        /// Accepted, but longer than `warnSeconds`.
        case long(TimeInterval)
        case tooLong(TimeInterval)
        case tooBig
        case unreadable

        var isAccepted: Bool {
            switch self {
            case .ok, .long: true
            case .tooLong, .tooBig, .unreadable: false
            }
        }

        var logName: String {
            switch self {
            case .ok(let seconds): "ok(\(String(format: "%.2f", seconds))s)"
            case .long(let seconds): "long(\(String(format: "%.2f", seconds))s)"
            case .tooLong(let seconds): "too-long(\(String(format: "%.2f", seconds))s)"
            case .tooBig: "too-big"
            case .unreadable: "unreadable"
            }
        }
    }

    enum ImportError: Error, Equatable {
        case rejected(Check)
        case copyFailed
    }

    struct Imported: Equatable {
        /// Name inside `directory`.
        var fileName: String
        /// The original file name, for the menu.
        var displayName: String
        var check: Check
    }

    let directory: URL

    init(directory: URL = AppGroup.containerURL.appendingPathComponent("Sounds", isDirectory: true)) {
        self.directory = directory
    }

    /// Pure decision from what the file is.
    static func check(duration: TimeInterval?, bytes: Int?) -> Check {
        if let bytes, bytes > maxBytes { return .tooBig }
        guard let duration, duration.isFinite, duration > 0 else { return .unreadable }
        if duration > maxSeconds { return .tooLong(duration) }
        if duration > warnSeconds { return .long(duration) }
        return .ok(duration)
    }

    /// Seconds of audio, nil if the file cannot be decoded.
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }

    static func check(_ url: URL) -> Check {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let bytes, bytes > maxBytes { return .tooBig }
        return check(duration: duration(of: url), bytes: bytes)
    }

    /// Checks `source` and copies it in under a new name ("start-<uuid>.<ext>"). The previous file
    /// of that cue is not touched here (see `remove`).
    func importFile(_ source: URL, for kind: CueKind) throws -> Imported {
        let check = Self.check(source)
        guard check.isAccepted else { throw ImportError.rejected(check) }
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let name = "\(kind.rawValue)-\(UUID().uuidString).\(ext)"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: url(for: name))
        } catch {
            throw ImportError.copyFailed
        }
        return Imported(fileName: name, displayName: source.deletingPathExtension().lastPathComponent, check: check)
    }

    func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    func exists(_ fileName: String?) -> Bool {
        guard let fileName else { return false }
        return FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    /// Deletes a stored file (only names inside `directory`).
    func remove(_ fileName: String?) {
        guard let fileName, !fileName.contains("/") else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}
