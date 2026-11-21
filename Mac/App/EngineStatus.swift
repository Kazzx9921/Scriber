import AppKit
import Foundation
import Observation
import ScriberShared

/// What the windows show about the running app: permissions, the hotkey that works, the dictation
/// phase and the newest result, plus the few actions the windows trigger (ask for a permission,
/// relaunch, pause the hotkey while choosing a key).
///
/// `EngineStatus.live` mirrors `DictationController` and `HotkeyRuntime` through Observation, so
/// views never depend on the controller directly. Snapshot renders build a sample instance whose
/// actions do nothing (no prompts, no microphone, no hotkey changes).
@MainActor
@Observable
final class EngineStatus {
    enum Phase: Equatable {
        case idle, recording, processing
    }

    struct Result: Equatable {
        var id: UUID
        var text: String
        var date: Date
    }

    var micPermission: MicPermission
    var accessibilityTrusted: Bool
    var hotkey: HotkeyRuntimeState
    var phase: Phase
    /// The app holding secure keyboard entry, when on ("" if unknown).
    var secureInputOwner: String?
    /// Newest successful dictation of this session.
    var latestResult: Result?

    @ObservationIgnored let isLive: Bool

    /// Accessibility is on but the single-key hotkey could not start; a relaunch fixes it.
    var needsRelaunch: Bool { accessibilityTrusted && hotkey.tapFailed }

    // MARK: Live instance

    static let live: EngineStatus = {
        let status = EngineStatus(live: ())
        status.track()
        return status
    }()

    private init(live: Void) {
        isLive = true
        micPermission = .notDetermined
        accessibilityTrusted = false
        hotkey = HotkeyRuntimeState()
        phase = .idle
    }

    /// Sample state for snapshot renders and previews.
    init(sample micPermission: MicPermission = .granted, accessibilityTrusted: Bool = false,
         hotkey: HotkeyRuntimeState = HotkeyRuntimeState(active: .combo(.optionSpace), combo: .registered),
         phase: Phase = .idle, secureInputOwner: String? = nil, latestResult: Result? = nil) {
        isLive = false
        self.micPermission = micPermission
        self.accessibilityTrusted = accessibilityTrusted
        self.hotkey = hotkey
        self.phase = phase
        self.secureInputOwner = secureInputOwner
        self.latestResult = latestResult
    }

    private struct Mirror: Equatable {
        var mic: MicPermission
        var trusted: Bool
        var hotkey: HotkeyRuntimeState
        var phase: Phase
        var secureInputOwner: String?
        var latest: Result?
    }

    /// Copies the controller's state now and again whenever it changes.
    private func track() {
        let mirror = withObservationTracking {
            Self.read()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.track() }
        }
        if micPermission != mirror.mic { micPermission = mirror.mic }
        if accessibilityTrusted != mirror.trusted { accessibilityTrusted = mirror.trusted }
        if hotkey != mirror.hotkey { hotkey = mirror.hotkey }
        if phase != mirror.phase { phase = mirror.phase }
        if secureInputOwner != mirror.secureInputOwner { secureInputOwner = mirror.secureInputOwner }
        if latestResult != mirror.latest { latestResult = mirror.latest }
    }

    private static func read() -> Mirror {
        let controller = DictationController.shared
        let phase: Phase = switch controller.phase {
        case .idle: .idle
        case .recording: .recording
        case .processing: .processing
        }
        return Mirror(
            mic: controller.micPermission,
            trusted: controller.accessibilityTrusted,
            hotkey: HotkeyRuntime.shared.state,
            phase: phase,
            secureInputOwner: controller.secureInputActive ? (controller.secureInputOwnerName ?? "") : nil,
            latest: controller.recent.first.map { Result(id: $0.id, text: $0.text, date: $0.date) })
    }

    // MARK: Actions

    /// Re-reads permissions and the hotkey (cheap, never prompts).
    func refresh() {
        guard isLive else { return }
        DictationController.shared.refreshEnvironment()
    }

    /// Shows the system microphone prompt the first time. Returns whether it is granted.
    @discardableResult
    func requestMicrophone() async -> Bool {
        guard isLive else { return false }
        let granted = await Permissions.requestMicrophone()
        refresh()
        return granted
    }

    func openMicrophoneSettings() {
        guard isLive else { return }
        Permissions.openMicrophoneSettings()
    }

    /// Adds Scriber to the Accessibility list and shows macOS's own prompt (which offers to open
    /// System Settings).
    func requestAccessibility() {
        guard isLive else { return }
        DiagLog.log("app", "auto-paste: asking for accessibility")
        Permissions.promptAccessibility()
    }

    func openAccessibilitySettings() {
        guard isLive else { return }
        Permissions.openAccessibilitySettings()
    }

    func relaunch() {
        guard isLive else { return }
        Permissions.relaunch()
    }

    /// While a settings control listens for a new hotkey.
    func pauseHotkey(_ paused: Bool) {
        guard isLive else { return }
        DictationController.shared.pauseHotkey(paused)
    }
}
