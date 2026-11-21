import Foundation

// CONTRACT FILE — shared by the app and the keyboard extension.

/// Tiny shared diagnostic log in the App Group container, so problems on a real device can be
/// read in Settings → 診斷紀錄 without a cable. Both processes append to the same file.
///
/// Rules: log events and states only. NEVER log transcripts, dictated text, selected text,
/// API keys, or anything else the user said or typed.
public enum DiagLog {
    private static let queue = DispatchQueue(label: "com.geekaz.Scriber.diaglog")
    private static let maxBytes = 200_000

    private static var fileURL: URL {
        AppGroup.containerURL.appendingPathComponent("diagnostics.log")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// `source` is a short tag: "app", "kb", "engine", "rec", "pipe"…
    public static func log(_ source: String, _ message: String) {
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) [\(source)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = fileURL
            // O_APPEND makes each write land at the end atomically, so the app and the
            // keyboard can log at the same moment without overwriting each other's lines.
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
            // Trim occasionally: keep the newest half once the file is too big.
            if lseek(fd, 0, SEEK_END) > off_t(maxBytes), let all = try? Data(contentsOf: url) {
                try? all.suffix(maxBytes / 2).write(to: url, options: .atomic)
            }
        }
    }

    public static func read() -> String {
        queue.sync { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }
    }

    public static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }
}
