import Carbon
import Foundation
import ScriberShared

/// Global key combinations through Carbon's `RegisterEventHotKey`. Needs no permission: macOS
/// delivers the combination to Scriber and to nobody else, so it works before Accessibility is
/// granted (see `HotkeySelection`).
///
/// - Registered with `kEventHotKeyExclusive`, so a combination another app (or macOS itself, e.g.
///   Spotlight's ⌘Space) already owns fails with `eventHotKeyExistsErr` instead of firing in both.
/// - System shortcuts that do not register hot keys (input source switching ⌃Space / ⌃⌥Space…)
///   are found in the symbolic hot key table first.
/// - Esc is registered separately, only while a dictation records on this path.
/// Main thread only (Carbon event dispatch happens on the main run loop).
final class ComboHotkeys {
    enum Kind: Equatable {
        case binding(ComboBinding)
        /// A mode's own combination (registered whatever the permission).
        case mode(ModeComboBinding)
        case escape
    }

    /// Main thread.
    var onPress: ((Kind) -> Void)?
    /// Main thread.
    var onRelease: ((Kind) -> Void)?

    private struct Registration {
        var ref: EventHotKeyRef
        var kind: Kind
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var pressed: Set<UInt32> = []
    private static let signature: OSType = 0x5343_5242 // 'SCRB'

    deinit {
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    // MARK: Bindings

    /// Replaces the registered combinations. The first binding (plain dictation) decides the
    /// outcome; a variant that cannot be registered is skipped and logged.
    func register(_ bindings: [ComboBinding]) -> ComboRegistration {
        unregisterBindings()
        guard let first = bindings.first else { return .off }
        installHandlerIfNeeded()
        if Self.isSystemShortcut(first.combo) {
            DiagLog.log("hotkey", "combo \(first.combo.logDescription) is a macOS shortcut → not registered")
            return .taken(.system)
        }
        var outcome = ComboRegistration.registered
        for (index, binding) in bindings.enumerated() {
            let status = add(.binding(binding), keyCode: binding.combo.keyCode, modifiers: binding.combo.carbonModifiers,
                             exclusive: true)
            guard status != noErr else { continue }
            let conflict: ComboConflict = status == OSStatus(eventHotKeyExistsErr) ? .otherApp : .failed
            DiagLog.log("hotkey", "combo \(binding.combo.logDescription) (\(binding.variant.logName)) not registered "
                        + "status=\(status) → \(conflict.rawValue)")
            if index == 0 {
                outcome = .taken(conflict)
                break
            }
        }
        if case .taken = outcome { unregisterBindings() }
        return outcome
    }

    func unregisterBindings() {
        for (id, registration) in registrations {
            if case .binding = registration.kind {
                UnregisterEventHotKey(registration.ref)
                registrations[id] = nil
                pressed.remove(id)
            }
        }
    }

    // MARK: Modes' own combinations

    /// Replaces the modes' combinations. Each one succeeds or fails on its own (exclusive, like
    /// the main combination; macOS shortcuts from the system table are not registered).
    func registerModes(_ bindings: [ModeComboBinding]) -> [String: ComboRegistration] {
        unregisterModes()
        guard !bindings.isEmpty else { return [:] }
        installHandlerIfNeeded()
        var outcome: [String: ComboRegistration] = [:]
        for binding in bindings {
            if Self.isSystemShortcut(binding.combo) {
                outcome[binding.modeID] = .taken(.system)
                continue
            }
            let status = add(.mode(binding), keyCode: binding.combo.keyCode, modifiers: binding.combo.carbonModifiers,
                             exclusive: true)
            if status == noErr {
                outcome[binding.modeID] = .registered
            } else {
                let conflict: ComboConflict = status == OSStatus(eventHotKeyExistsErr) ? .otherApp : .failed
                outcome[binding.modeID] = .taken(conflict)
                DiagLog.log("hotkey", "mode combo \(binding.combo.logDescription) (\(binding.variant.logName)) not registered "
                            + "status=\(status) → \(conflict.rawValue)")
            }
        }
        return outcome
    }

    func unregisterModes() {
        for (id, registration) in registrations {
            if case .mode = registration.kind {
                UnregisterEventHotKey(registration.ref)
                registrations[id] = nil
                pressed.remove(id)
            }
        }
    }

    // MARK: Escape

    var isEscapeRegistered: Bool {
        registrations.values.contains { $0.kind == .escape }
    }

    /// Esc cancels a recording that was started with the combination. Not exclusive: it only
    /// needs to reach Scriber while recording, and is removed right after.
    func setEscape(_ enabled: Bool) {
        guard enabled != isEscapeRegistered else { return }
        if enabled {
            installHandlerIfNeeded()
            let status = add(.escape, keyCode: KeyCodes.escape, modifiers: 0, exclusive: false)
            if status != noErr { DiagLog.log("hotkey", "esc not registered status=\(status)") }
        } else {
            for (id, registration) in registrations where registration.kind == .escape {
                UnregisterEventHotKey(registration.ref)
                registrations[id] = nil
                pressed.remove(id)
            }
        }
    }

    func unregisterAll() {
        unregisterBindings()
        unregisterModes()
        setEscape(false)
    }

    // MARK: Private

    private func add(_ kind: Kind, keyCode: UInt16, modifiers: UInt32, exclusive: Bool) -> OSStatus {
        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(), exclusive ? OptionBits(kEventHotKeyExclusive) : 0, &ref)
        if status == noErr, let ref {
            registrations[id] = Registration(ref: ref, kind: kind)
        }
        return status
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), comboHotkeyCallback, specs.count, &specs,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { DiagLog.log("hotkey", "combo event handler not installed status=\(status)") }
    }

    fileprivate func handle(id: EventHotKeyID, pressed isPress: Bool) {
        guard id.signature == Self.signature, let registration = registrations[id.id] else { return }
        if isPress {
            // Holding the keys may repeat the press; one press until the release.
            guard pressed.insert(id.id).inserted else { return }
            onPress?(registration.kind)
        } else {
            pressed.remove(id.id)
            onRelease?(registration.kind)
        }
    }

    /// Whether an enabled macOS shortcut uses this combination (the table uses Carbon modifiers).
    static func isSystemShortcut(_ combo: KeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let wanted = combo.carbonModifiers
        return entries.contains { entry in
            guard (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true,
                  (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue == Int(combo.keyCode),
                  let modifiers = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return false }
            return modifiers & KeyCombo.carbonModifierMask == wanted
        }
    }
}

/// Carbon callback; `userData` is the unretained `ComboHotkeys` (owned by the hotkey monitor,
/// which lives as long as the app).
private let comboHotkeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let hotkeys = Unmanaged<ComboHotkeys>.fromOpaque(userData).takeUnretainedValue()
    hotkeys.handle(id: id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
    return noErr
}
