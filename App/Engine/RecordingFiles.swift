import Foundation
import UIKit

/// Where clips live: the app's own Caches (the keyboard never reads audio). Clips are deleted
/// after the pipeline; a clip kept for retry is deleted on the next dictation, and anything a
/// crash left behind is purged at launch.
struct RecordingFiles {
    let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = caches.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Base URL without extension; `CaptureBuffer` picks .m4a or .wav.
    func newClipBaseURL() -> URL {
        directory.appendingPathComponent(UUID().uuidString)
    }

    func delete(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func purge(olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for url in items {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}

/// `beginBackgroundTask` wrapper so network work finishes even when nothing else keeps the
/// app running (in-app test after the user leaves, or a session whose audio was interrupted).
@MainActor
final class BackgroundActivity {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String, onExpire: (() -> Void)? = nil) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpire?()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
