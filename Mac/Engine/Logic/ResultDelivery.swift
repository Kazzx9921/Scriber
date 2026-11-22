import Foundation
import ScriberShared

/// What happens to a finished result (docs/PRD-模式.md §4): pasted at the cursor (or over the
/// selection), only put on the clipboard, or shown in the answer panel. Only a paste can be
/// followed by an automatic Return (§7.5).
enum ResultDelivery: Equatable {
    case paste(autoSend: ModeAutoSend)
    case copyOnly
    case answer

    init(output: ModeOutput, autoSend: ModeAutoSend) {
        switch output {
        case .paste, .replaceSelection: self = .paste(autoSend: autoSend)
        case .copyOnly: self = .copyOnly
        case .answer: self = .answer
        }
    }

    /// The text is typed into the app in front (⌘V).
    var pastes: Bool {
        if case .paste = self { return true }
        return false
    }

    var logName: String {
        switch self {
        case .paste(let autoSend): autoSend == .none ? "paste" : "paste+\(autoSend.rawValue)"
        case .copyOnly: "copyOnly"
        case .answer: "answer"
        }
    }
}

/// The key pressed after a paste.
struct AutoSendKey: Equatable {
    var keyCode: UInt16
    var command: Bool

    static let returnKey = AutoSendKey(keyCode: KeyCodes.returnKey, command: false)
    static let commandReturn = AutoSendKey(keyCode: KeyCodes.returnKey, command: true)

    var logName: String { command ? "cmdReturn" : "return" }
}

/// When the automatic Return may be pressed: only after ⌘V really went to the app, and only into the
/// same app that got the paste. Never after copy-only, the answer panel, or text left on the
/// clipboard because pasting could not work (no Accessibility, secure input, events refused).
enum AutoSendGate {
    /// Between ⌘V and the Return: the app inserts the text first (Electron apps paste asynchronously).
    /// Well inside `PasteRestorePolicy.restoreDelay`, which only concerns the pasteboard.
    static let delay: TimeInterval = 0.25

    enum PasteResult: Equatable {
        /// ⌘V was posted.
        case pasted
        /// Left on the clipboard for the user to paste (or not pasted at all).
        case notPasted
    }

    /// `sameAppInFront`: the app that got the paste is still in front after `delay`.
    static func key(for delivery: ResultDelivery, paste: PasteResult?, sameAppInFront: Bool,
                    secureInput: Bool) -> AutoSendKey? {
        guard case .paste(let autoSend) = delivery, paste == .pasted, sameAppInFront, !secureInput else { return nil }
        switch autoSend {
        case .none: return nil
        case .returnKey: return .returnKey
        case .commandReturn: return .commandReturn
        }
    }
}
