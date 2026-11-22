import Foundation

/// A cancellable piece of delayed work.
@MainActor
final class AudioTimer {
    private(set) var isCancelled = false

    func cancel() { isCancelled = true }
}

/// Time for the audio session (deferred mute, delayed resume). The app uses `MainQueueScheduler`;
/// tests drive a fake clock.
@MainActor
protocol AudioScheduling: AnyObject {
    var now: Date { get }
    @discardableResult
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AudioTimer
}

/// Main-queue timers. They count awake time (`DispatchTime`), so after a sleep they fire late in
/// wall-clock terms; `MediaPauseCoordinator` uses that to avoid starting music after waking.
@MainActor
final class MainQueueScheduler: AudioScheduling {
    var now: Date { Date() }

    @discardableResult
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AudioTimer {
        let timer = AudioTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) {
            MainActor.assumeIsolated {
                guard !timer.isCancelled else { return }
                work()
            }
        }
        return timer
    }
}
