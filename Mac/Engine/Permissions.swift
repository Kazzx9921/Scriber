import AppKit
import AVFoundation
import ApplicationServices
import Carbon

enum MicPermission: String, Sendable {
    case notDetermined, granted, denied, restricted
}

/// Microphone, Accessibility and secure-input state, plus the System Settings deep links.
/// Nothing here prompts unless the name says so.
enum Permissions {
    // MARK: Microphone

    static var microphone: MicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Shows the system prompt the first time; afterwards returns the stored answer.
    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: Accessibility

    /// Needed for the single-key hotkey (event tap), for posting ⌘V / ⌘C (automatic paste,
    /// 說話改字) and for reading the selection. Without it Scriber still works: the key combination
    /// hotkey needs no permission and results go to the clipboard (see `HotkeySelection`).
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Adds Scriber to the Accessibility list (switched off) and shows the system's
    /// "open System Settings" prompt, so the user only has to flip the switch. Only from the
    /// 開啟自動貼上 screen, after explaining what the permission is for.
    static func promptAccessibility() {
        // The documented value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Secure input

    /// True while any app has secure keyboard entry on (a password field, Terminal's "Secure
    /// Keyboard Entry", some password managers). Then the event tap sees no keys and pasting is
    /// refused by design.
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// The app holding secure input, from the window server's session dictionary (best effort).
    static func secureInputOwner() -> NSRunningApplication? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        let raw = session["kCGSSessionSecureInputPID"]
        let pid = (raw as? Int).map { pid_t($0) } ?? (raw as? NSNumber).map { pid_t($0.int32Value) }
        guard let pid, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    // MARK: Pasteboard privacy (macOS 15.4+)

    /// How macOS treats Scriber reading the general pasteboard: "default"/"ask" may show a prompt,
    /// "alwaysDeny" makes reads fail silently.
    static var pasteboardAccess: String {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .default: return "default"
            case .ask: return "ask"
            case .alwaysAllow: return "alwaysAllow"
            case .alwaysDeny: return "alwaysDeny"
            @unknown default: return "unknown"
            }
        }
        return "n/a"
    }

    static var canReadPasteboard: Bool {
        if #available(macOS 15.4, *) {
            return NSPasteboard.general.accessBehavior != .alwaysDeny
        }
        return true
    }

    // MARK: Relaunch

    /// Starts a fresh copy of the app a moment after this one quits (some macOS versions only
    /// honour a new Accessibility grant in a new process).
    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try task.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
