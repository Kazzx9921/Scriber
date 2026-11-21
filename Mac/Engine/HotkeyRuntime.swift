import Observation

/// The hotkey that works right now, published by `HotkeyMonitor` (main thread) for the windows and
/// the menu, so every screen shows the key that actually starts a dictation.
@MainActor
@Observable
final class HotkeyRuntime {
    static let shared = HotkeyRuntime()

    var state = HotkeyRuntimeState()

    func update(_ new: HotkeyRuntimeState) {
        if state != new { state = new }
    }
}
