import Foundation
import ScriberShared

/// Menu bar icon and status line that know about the two hotkeys: working without Accessibility
/// (key combination + ⌘V) is a normal mode, not a problem, and the line always names the hotkey
/// that actually works (`HotkeyRuntime`). Only reads the controller's public state.
extension DictationController {
    /// The HUD's "請按 ⌘V 貼上" is the expected outcome without Accessibility, not an error.
    private var lastProblemIsManualPaste: Bool {
        lastProblem?.type == "copied-no-ax"
    }

    /// Something stops dictation from working at all.
    var presentedNeedsAttention: Bool {
        if micPermission == .denied || micPermission == .restricted { return true }
        if case .unavailable(.comboTaken) = HotkeyRuntime.shared.state.active { return true }
        return false
    }

    var presentedMenuBarSymbol: String {
        guard phase == .idle else { return menuBarSymbol }
        if presentedNeedsAttention { return "mic.slash" }
        if errorFlash, !lastProblemIsManualPaste { return "exclamationmark.circle" }
        return "mic"
    }

    var presentedStatusLine: String {
        guard phase == .idle else { return statusLine }
        if micPermission == .denied || micPermission == .restricted { return "需要麥克風權限" }
        let hotkey = HotkeyRuntime.shared.state
        if secureInputActive {
            let who = secureInputOwnerName.map { "「\($0)」" } ?? "某個 App"
            return "\(who)正在使用安全輸入，快捷鍵暫停"
        }
        if let lastProblem, !lastProblemIsManualPaste { return lastProblem.message }
        let hold = MacSettings.shared.hotkey.mode == .hold
        switch hotkey.active {
        case .single(let key):
            return hold ? "按住 \(key.shortName) 說話" : "按一下 \(key.shortName) 開始說話"
        case .combo(let combo):
            return hold ? "按住 \(combo.displayName) 說話" : "按 \(combo.displayName) 開始說話"
        case .unavailable(.comboTaken(let conflict)):
            return "\(MacSettings.shared.hotkey.combo.displayName) \(conflict.label)，請到設定換一組"
        case .unavailable(.paused):
            return "正在設定快捷鍵…"
        case .unavailable(.starting):
            return "快捷鍵準備中…"
        }
    }
}
