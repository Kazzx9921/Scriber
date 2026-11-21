import AppKit
import ApplicationServices

/// What has keyboard focus in other apps, through the Accessibility API. Every call has a short
/// messaging timeout (set once at launch) so a hung app cannot freeze Scriber.
enum FocusInfo {
    /// Global AX messaging timeout for this process (the default is about 6 s).
    static func configureTimeout(_ seconds: Float = 0.4) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// The focused UI element anywhere on the system, or the AX error code.
    static func focusedElement() -> (element: AXUIElement?, error: AXError) {
        guard AXIsProcessTrusted() else { return (nil, .apiDisabled) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                  kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (nil, error == .success ? .noValue : error)
        }
        return ((value as! AXUIElement), .success)
    }

    /// AX role of the focused element (e.g. "AXTextArea"), for the diagnostic log. Never content.
    static func focusedRole() -> String {
        let (element, error) = focusedElement()
        guard let element else { return "none(\(error.rawValue))" }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return "unknown" }
        return role
    }

    /// Frame of the frontmost app's focused window in Cocoa screen coordinates (origin bottom-left).
    static func focusedWindowFrame() -> CGRect? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = windowValue as! AXUIElement
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        // AX uses top-left origin coordinates relative to the primary screen.
        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.maxY - origin.y - size.height
        return CGRect(x: origin.x, y: flippedY, width: size.width, height: size.height)
    }

    /// The screen the user is working on: the one holding the focused window, else the one under
    /// the mouse, else the main screen.
    @MainActor
    static func activeScreen() -> NSScreen? {
        if let frame = focusedWindowFrame() {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// Reads the selected text in the frontmost app for 說話改字.
enum SelectionReader {
    enum AXResult: Sendable, Equatable {
        case text(String)
        /// The element answered and nothing is selected.
        case empty
        /// The element does not expose its selection (Electron, terminals, some web views…).
        case unavailable(String)
    }

    /// Accessibility first: no side effects. Safe off the main thread.
    static func readViaAccessibility() -> AXResult {
        let (element, error) = FocusInfo.focusedElement()
        guard let element else { return .unavailable("focus=\(error.rawValue)") }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard status == .success else { return .unavailable("selectedText=\(status.rawValue)") }
        guard let text = value as? String else { return .unavailable("selectedText=type") }
        return text.isEmpty ? .empty : .text(text)
    }

    /// ⌘C fallback: borrow the pasteboard, ask the app to copy, read the copy, give the
    /// pasteboard back. Returns the text (nil when nothing was copied) and a log token.
    ///
    /// Limits: the app's own copy lands in clipboard managers' history (Scriber cannot mark
    /// another app's write); some editors copy the whole line when nothing is selected.
    @MainActor
    static func readViaCopy() async -> (text: String?, detail: String) {
        guard Permissions.isAccessibilityTrusted else { return (nil, "no-accessibility") }
        guard !Permissions.secureInputActive else { return (nil, "secure-input") }
        guard Permissions.canReadPasteboard else { return (nil, "pasteboard-denied") }
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let before = pasteboard.changeCount
        _ = await SyntheticKeys.waitForModifiersReleased()
        let keyCode = KeyboardLayout.keyCode(for: "c", fallback: KeyCodes.ansiC)
        guard SyntheticKeys.postCommand(keyCode: keyCode) else { return (nil, "post-failed") }
        let deadline = Date().addingTimeInterval(PasteRestorePolicy.copyTimeout)
        while pasteboard.changeCount == before, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(PasteRestorePolicy.copyPollInterval * 1_000_000_000))
        }
        guard pasteboard.changeCount != before else { return (nil, "no-copy") }
        // Let the app finish writing all its types.
        try? await Task.sleep(nanoseconds: 40_000_000)
        let copied = pasteboard.string(forType: .string)
        let afterCopy = pasteboard.changeCount
        if PasteRestorePolicy.shouldRestore(snapshot: snapshot, ourChangeCount: afterCopy,
                                            currentChangeCount: pasteboard.changeCount) {
            snapshot.restore(to: pasteboard)
        }
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, "copied-empty")
        }
        return (copied, "ok")
    }
}
