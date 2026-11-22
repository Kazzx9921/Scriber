import UIKit
import ScriberCore
import ScriberShared

/// Keeps file transcription going as far as iOS allows:
/// - While a job runs in the foreground the screen stays awake (`isIdleTimerDisabled`).
/// - When the app goes to the background with work in progress, a background task asks for
///   extra time (usually tens of seconds). When it runs out, the queue pauses without losing
///   finished segments (they are on disk) and the task ends.
/// - Back in the foreground, paused work continues where it stopped.
/// No background `URLSession` uploads: segments in flight when iOS suspends the app are redone.
@MainActor
final class TranscriptionLifecycle {
    static let shared = TranscriptionLifecycle()

    private weak var queue: TranscriptionQueue?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var busy = false

    func attach(_ queue: TranscriptionQueue) {
        guard self.queue !== queue else { return }
        self.queue = queue
        queue.onActivityChange = { [weak self] busy in self?.activityChanged(busy) }
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteredBackground() }
            })
            observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enteringForeground() }
            })
        }
        activityChanged(queue.isActive || queue.jobs.contains { $0.phase == .waiting })
    }

    private func activityChanged(_ busy: Bool) {
        self.busy = busy
        UIApplication.shared.isIdleTimerDisabled = busy
        if !busy { endBackgroundTask() }
    }

    private func enteredBackground() {
        guard busy, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Scriber transcription") { [weak self] in
            MainActor.assumeIsolated {
                DiagLog.log("transcribe", "background time is up: pausing")
                self?.queue?.pauseAll()
                self?.endBackgroundTask()
            }
        }
        DiagLog.log("transcribe", "background: continuing (remaining=\(Int(min(UIApplication.shared.backgroundTimeRemaining, 9999)))s)")
    }

    private func enteringForeground() {
        endBackgroundTask()
        queue?.resumeAutoPaused()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
