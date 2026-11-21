import Foundation

// Which hotkey works right now. Scriber listens in two ways:
// - **single**: a lone modifier (right ⌥…) through the event tap. Needs Accessibility, which also
//   enables automatic paste and 說話改字.
// - **combo**: a key combination (⌥Space…) through Carbon's `RegisterEventHotKey`. Needs no
//   permission, so it works the moment the app starts; results go to the clipboard for ⌘V.
// When Accessibility is granted the single key takes over as soon as the tap runs; until then (and
// whenever the tap cannot start) the combination keeps working, so there is never a gap.
// Pure and Foundation-only: tested in the logic test bundle.

/// Outcome of registering the key combination with the system.
enum ComboRegistration: Equatable, Sendable {
    /// Not registered (the single key is active, or the hotkey is paused).
    case off
    case registered
    case taken(ComboConflict)
}

enum ComboConflict: String, Equatable, Sendable {
    /// Another app already owns the combination.
    case otherApp
    /// A macOS shortcut (System Settings › Keyboard › Shortcuts) uses it.
    case system
    /// macOS refused it for another reason.
    case failed

    /// A few words for the UI.
    var label: String {
        switch self {
        case .otherApp: "已被其他 App 使用"
        case .system: "跟 macOS 的快捷鍵重複"
        case .failed: "macOS 不接受這組按鍵"
        }
    }
}

/// The hotkey that actually works right now: what every screen and the menu show.
enum ActiveHotkey: Equatable, Sendable {
    case single(TriggerKey)
    case combo(KeyCombo)
    case unavailable(Reason)

    enum Reason: Equatable, Sendable {
        /// Launching: nothing registered yet.
        case starting
        /// The settings screen is listening for a new key.
        case paused
        /// The combination could not be registered (and there is no Accessibility to fall back on).
        case comboTaken(ComboConflict)
    }

    /// Keycaps to draw ("右 ⌥" / "⌥", "Space"); empty when nothing works.
    var keycaps: [String] {
        switch self {
        case .single(let key): [key.shortName]
        case .combo(let combo): combo.keycaps
        case .unavailable: []
        }
    }

    var isWorking: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// One combination to register and what it means.
struct ComboBinding: Hashable, Sendable {
    var combo: KeyCombo
    var variant: HotkeyVariant
}

/// What the hotkey monitor publishes for the UI.
struct HotkeyRuntimeState: Equatable, Sendable {
    var active: ActiveHotkey = .unavailable(.starting)
    var combo: ComboRegistration = .off
    /// Accessibility is granted but the event tap could not be created (a relaunch usually helps).
    var tapFailed = false
}

enum HotkeySelection {
    struct Plan: Equatable, Sendable {
        /// Create the event tap (lone modifier).
        var runTap: Bool
        /// Keep the key combination registered.
        var registerCombo: Bool
    }

    /// Which listeners should run. The combination stays registered until the tap is actually
    /// running, so granting Accessibility never leaves a moment without a working hotkey, and a tap
    /// that cannot start falls back to the combination.
    static func plan(accessibilityTrusted: Bool, tapRunning: Bool, paused: Bool) -> Plan {
        Plan(runTap: accessibilityTrusted,
             registerCombo: !paused && !(accessibilityTrusted && tapRunning))
    }

    /// The hotkey that works, given the permission and the listeners' states.
    static func active(config: HotkeyConfig, accessibilityTrusted: Bool, tapRunning: Bool,
                       combo: ComboRegistration, paused: Bool) -> ActiveHotkey {
        if paused { return .unavailable(.paused) }
        if accessibilityTrusted, tapRunning { return .single(config.trigger) }
        switch combo {
        case .registered: return .combo(config.combo)
        case .taken(let conflict): return .unavailable(.comboTaken(conflict))
        case .off: return .unavailable(.starting)
        }
    }

    /// The combinations to register: plain dictation, then translate (and 說話改字, which needs
    /// Accessibility to read the selection) with their modifier added. A variant whose modifier is
    /// already part of the combination cannot be told apart and is left out; when both variants use
    /// the same modifier, 說話改字 wins (same rule as the single key).
    static func comboBindings(for config: HotkeyConfig, includeEdit: Bool) -> [ComboBinding] {
        let base = config.combo
        var bindings = [ComboBinding(combo: base, variant: .dictate)]
        let edit = includeEdit ? usableFamily(config.editModifier, in: base) : nil
        if let edit {
            bindings.append(ComboBinding(combo: base.adding(edit), variant: .edit))
        }
        if config.translateModifier != config.editModifier, let translate = usableFamily(config.translateModifier, in: base) {
            bindings.append(ComboBinding(combo: base.adding(translate), variant: .translate))
        }
        return bindings
    }

    /// Esc is registered as a global combination only while recording on the combination path
    /// (the event tap handles it otherwise).
    static func wantsEscape(recording: Bool, plan: Plan, combo: ComboRegistration) -> Bool {
        recording && plan.registerCombo && combo == .registered
    }

    private static func usableFamily(_ modifier: VariantModifier, in combo: KeyCombo) -> ModifierFamily? {
        guard let family = modifier.family, !combo.modifiers.contains(family) else { return nil }
        return family
    }
}
