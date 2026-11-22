import Foundation

/// One keyboard/mouse event from the event tap, reduced to what the state machine needs.
enum HotkeyInput: Equatable, Sendable {
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    /// `flags`: the modifier flags with the key (selects a variant when a function key is the trigger).
    case keyDown(keyCode: UInt16, isRepeat: Bool, flags: UInt64 = 0)
    case keyUp(keyCode: UInt16)
    case mouseDown
    /// Timer tick (hold mode: decides whether the press has been held long enough).
    case tick
}

/// What the hotkey means for dictation. The controller maps these onto start / stop / cancel
/// depending on its own state (idle, recording, processing).
enum HotkeyEvent: Equatable, Sendable {
    /// Toggle mode: a clean press-and-release of the trigger.
    case tap(HotkeyVariant)
    /// Hold mode: the trigger has been held long enough with nothing else pressed.
    case holdBegan(HotkeyVariant)
    /// Hold mode: released after `holdBegan`.
    case holdEnded
    /// Hold mode: another key or a click joined the press after `holdBegan` — the user is using the
    /// modifier in a combination, so the dictation is dropped silently.
    case holdAborted
    /// Escape while a dictation is recording.
    case escape
}

/// Lone-modifier detection, tap vs hold, and Escape. Pure and deterministic: time is passed in.
///
/// Rules:
/// - Only the trigger key's own press and release count; modifier events are never swallowed.
/// - A function-key trigger (F1–F20) arrives as key down / key up. Its own events are swallowed
///   only when the press is Scriber's (clean, and meaning a dictation or a variant), so ⌘F5 and
///   the like still reach other apps.
/// - A press is "clean" when no ordinary key was down when it started and no ordinary key or mouse
///   button went down before it was released. Anything else is the modifier's normal use in a
///   combination (⌥E, ⌥-click…) and is ignored.
/// - Other modifiers held during the press (Shift, Control…) select a variant; an unmapped
///   combination is ignored.
/// - Escape is swallowed (and reported) only while recording.
struct HotkeyStateMachine: Sendable {
    /// Toggle mode: a press longer than this does not start dictation (holding ⌥ to look at
    /// alternate menu items and letting go is not a tap). Stopping has no limit.
    static let tapMaxDuration: TimeInterval = 0.8
    /// Hold mode: dictation starts after the trigger has been held this long without other input,
    /// so quick ⌥-combinations never touch the microphone.
    static let holdArmDelay: TimeInterval = 0.2

    struct Press: Equatable, Sendable {
        var start: TimeInterval
        var extras: Set<ModifierFamily>
        var dirty: Bool
        var armed = false
    }

    struct Output: Equatable, Sendable {
        var event: HotkeyEvent?
        /// Drop the event instead of passing it on (Escape while recording only).
        var swallow = false
        /// Ask the owner to send `.tick` after this many seconds.
        var tickAfter: TimeInterval?
        /// Why a trigger press did nothing, for the diagnostic log (never key codes of other keys).
        var note: String?
    }

    var config: HotkeyConfig
    /// The modes' hotkeys (`HotkeyRoutes`): which modifiers held with the trigger start which mode.
    /// nil: the pre-modes variants of `config` (說話改字 / 翻譯 modifiers).
    var routes: HotkeyRoutes?
    /// Set by the owner while a dictation is recording.
    var isRecording = false
    /// Set by the owner while the settings screen captures a new trigger key.
    var isPaused = false

    private(set) var press: Press?
    private var triggerIsDown = false
    /// A function-key trigger press that is Scriber's: its down, repeats and up are swallowed.
    private var ownsTriggerKey = false
    /// Ordinary keys that are down, with the last time they were seen (key down or auto-repeat).
    /// Entries expire, so a key-up the tap never saw (secure input, tap disabled) cannot block the
    /// trigger forever.
    private var heldKeys: [UInt16: TimeInterval] = [:]
    static let heldKeyExpiry: TimeInterval = 3
    private var swallowEscapeUp = false

    init(config: HotkeyConfig) {
        self.config = config
    }

    mutating func reset() {
        press = nil
        triggerIsDown = false
        ownsTriggerKey = false
        heldKeys.removeAll()
        swallowEscapeUp = false
    }

    mutating func handle(_ input: HotkeyInput, at time: TimeInterval) -> Output {
        switch input {
        case let .flagsChanged(keyCode, flags):
            return flagsChanged(keyCode: keyCode, flags: flags, time: time)
        case let .keyDown(keyCode, isRepeat, flags):
            return keyDown(keyCode: keyCode, isRepeat: isRepeat, flags: flags, time: time)
        case let .keyUp(keyCode):
            if config.trigger.isFunctionKey, config.trigger.keyCodes.contains(keyCode), triggerIsDown {
                triggerIsDown = false
                let swallow = ownsTriggerKey
                ownsTriggerKey = false
                var output = triggerReleased(time: time)
                output.swallow = swallow
                return output
            }
            heldKeys.removeValue(forKey: keyCode)
            if keyCode == KeyCodes.escape, swallowEscapeUp {
                swallowEscapeUp = false
                return Output(swallow: true)
            }
            return Output()
        case .mouseDown:
            return markDirty()
        case .tick:
            return tick(time: time)
        }
    }

    // MARK: Steps

    private mutating func flagsChanged(keyCode: UInt16, flags: UInt64, time: TimeInterval) -> Output {
        if config.trigger.keyCodes.contains(keyCode) {
            let down = isTriggerDown(flags)
            if down, !triggerIsDown {
                triggerIsDown = true
                return triggerPressed(flags: flags, time: time)
            }
            if !down, triggerIsDown {
                triggerIsDown = false
                return triggerReleased(time: time)
            }
            return Output()
        }
        guard var current = press else { return Output() }
        if keyCode == KeyCodes.capsLock { return Output() }
        if let family = ModifierFamily.of(keyCode: keyCode) {
            if family == config.trigger.family {
                // The other copy of the trigger's modifier: not a lone press any more.
                return markDirty()
            }
            if flags & family.flag != 0 {
                current.extras.insert(family)
                press = current
            }
            return Output()
        }
        // Fn (when it is not the trigger) or an unknown modifier joined the press.
        return markDirty()
    }

    private mutating func keyDown(keyCode: UInt16, isRepeat: Bool, flags: UInt64, time: TimeInterval) -> Output {
        if config.trigger.isFunctionKey, config.trigger.keyCodes.contains(keyCode) {
            return functionKeyPressed(isRepeat: isRepeat, flags: flags, time: time)
        }
        if keyCode == KeyCodes.escape, isRecording, !isPaused {
            swallowEscapeUp = true
            // The trigger press (if any) is used up: its release must not stop or start anything.
            if var current = press {
                current.dirty = true
                press = current
            }
            return Output(event: isRepeat ? nil : .escape, swallow: true)
        }
        heldKeys[keyCode] = time
        return markDirty()
    }

    private mutating func triggerPressed(flags: UInt64, time: TimeInterval) -> Output {
        guard !isPaused else {
            press = nil
            return Output()
        }
        var extras = ModifierFamily.held(in: flags)
        heldKeys = heldKeys.filter { time - $0.value < Self.heldKeyExpiry }
        var dirty = !heldKeys.isEmpty
        if let family = config.trigger.family {
            extras.remove(family)
            // The other copy of the same modifier is already held (e.g. left ⌥ with right ⌥).
            if flags & (family.deviceBits & ~config.trigger.deviceBit) != 0 { dirty = true }
        }
        press = Press(start: time, extras: extras, dirty: dirty)
        return config.mode == .hold ? Output(tickAfter: Self.holdArmDelay) : Output()
    }

    /// Key down of a function-key trigger (F1–F20).
    private mutating func functionKeyPressed(isRepeat: Bool, flags: UInt64, time: TimeInterval) -> Output {
        if isRepeat || triggerIsDown {
            // Auto-repeat of a press that is already decided.
            return Output(swallow: ownsTriggerKey)
        }
        guard !isPaused else {
            press = nil
            return Output()
        }
        triggerIsDown = true
        let extras = ModifierFamily.held(in: flags)
        heldKeys = heldKeys.filter { time - $0.value < Self.heldKeyExpiry }
        let dirty = !heldKeys.isEmpty
        // Ours when it means something: stopping a recording, or a dictation / variant to start.
        let meaningful = isRecording || variant(for: extras) != nil
        ownsTriggerKey = !dirty && meaningful
        press = Press(start: time, extras: extras, dirty: dirty)
        let tick = config.mode == .hold && ownsTriggerKey ? Self.holdArmDelay : nil
        return Output(swallow: ownsTriggerKey, tickAfter: tick)
    }

    private mutating func triggerReleased(time: TimeInterval) -> Output {
        guard let current = press else { return Output() }
        press = nil
        switch config.mode {
        case .toggle:
            guard !current.dirty else { return Output(note: "trigger ignored: used in a combination") }
            if isRecording {
                // Stopping: any clean press counts, however long, with or without other modifiers.
                return Output(event: .tap(variant(for: current.extras) ?? .dictate))
            }
            let held = time - current.start
            guard held <= Self.tapMaxDuration else {
                return Output(note: "trigger ignored: held \(String(format: "%.2f", held))s (tap limit \(Self.tapMaxDuration)s)")
            }
            guard let variant = self.variant(for: current.extras) else {
                return Output(note: "trigger ignored: with \(Self.describe(current.extras)) (no variant)")
            }
            return Output(event: .tap(variant))
        case .hold:
            // A dirty armed press already reported `holdAborted`; an unarmed one never started.
            if !current.armed {
                return Output(note: current.dirty ? "trigger ignored: used in a combination"
                                                  : "trigger ignored: released before the hold delay")
            }
            guard !current.dirty else { return Output() }
            return Output(event: .holdEnded)
        }
    }

    private mutating func tick(time: TimeInterval) -> Output {
        guard config.mode == .hold, var current = press, !current.armed, !current.dirty else { return Output() }
        let remaining = current.start + Self.holdArmDelay - time
        if remaining > 0.001 { return Output(tickAfter: remaining) }
        guard let variant = self.variant(for: current.extras) else {
            current.dirty = true
            press = current
            return Output(note: "trigger ignored: with \(Self.describe(current.extras)) (no variant)")
        }
        current.armed = true
        press = current
        return Output(event: .holdBegan(variant))
    }

    /// Something else joined the press: it is a combination, not a trigger.
    private mutating func markDirty() -> Output {
        guard var current = press, !current.dirty else { return Output() }
        current.dirty = true
        press = current
        return current.armed && config.mode == .hold ? Output(event: .holdAborted) : Output()
    }

    /// The variant for the other modifiers held with the trigger (nil: the press means nothing).
    private func variant(for extras: Set<ModifierFamily>) -> HotkeyVariant? {
        guard let routes else { return config.variant(for: extras) }
        return routes.variant(for: extras)
    }

    static func describe(_ families: Set<ModifierFamily>) -> String {
        families.isEmpty ? "none" : families.map(\.rawValue).sorted().joined(separator: "+")
    }

    private func isTriggerDown(_ flags: UInt64) -> Bool {
        let trigger = config.trigger
        guard let family = trigger.family else {
            return flags & trigger.deviceBit != 0 // Fn: the secondary-fn flag
        }
        guard flags & family.flag != 0 else { return false }
        if flags & family.deviceBits != 0 { return flags & trigger.deviceBit != 0 }
        // No device-dependent bits (some keyboards and remappers): an event for our key code
        // while the family is on toggles the state.
        return !triggerIsDown
    }
}
