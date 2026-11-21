import AppKit
import Carbon
import CoreGraphics

/// Posting ⌘V / ⌘C into the frontmost app.
enum SyntheticKeys {
    /// Written into `eventSourceUserData` of every event Scriber posts, so its own event tap
    /// ignores them ("SCRB").
    static let marker: Int64 = 0x5343_5242

    /// Posts ⌘+`keyCode` (down and up) at the session level. Returns false if the events could not
    /// be created. Needs Accessibility; without it macOS drops the events silently.
    @discardableResult
    static func postCommand(keyCode: UInt16) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Keep the user's mouse and system events flowing while ours are delivered.
        source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                          state: .eventSuppressionStateSuppressionInterval)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        // Explicit flags: only Command (left), whatever the user is still holding.
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | ModifierBits.leftCommand)
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// Waits (briefly) until no modifier is physically held, so the target app cannot mix a held
    /// Shift/Option into our ⌘V. Returns false on timeout (the events carry explicit flags anyway).
    @MainActor
    static func waitForModifiersReleased(timeout: TimeInterval = 0.5) async -> Bool {
        let held: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        let deadline = Date().addingTimeInterval(timeout)
        while CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty == false {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return true
    }
}

/// Finds the key code for a letter in the user's keyboard layout, so ⌘V is still "V" on Dvorak,
/// AZERTY and friends. Uses the ASCII-capable layout under the current input source (Zhuyin and
/// Pinyin sit on top of one) and asks which key produces the letter with ⌘ held, which also covers
/// "Dvorak – QWERTY ⌘". Main thread only (Text Input Sources).
enum KeyboardLayout {
    @MainActor
    static func keyCode(for character: Character, fallback: UInt16) -> UInt16 {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { buffer -> UInt16 in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            for modifiers in [commandState, 0] {
                for code in 0..<128 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), modifiers, keyboardType,
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                                chars.count, &length, &chars)
                    if status == noErr, length > 0,
                       String(utf16CodeUnits: chars, count: length).lowercased() == target {
                        return UInt16(code)
                    }
                }
            }
            return fallback
        }
    }
}
