import Foundation
import ScriberShared

// Auto-return: after the keyboard opened Scriber and recording has started, send the user back
// to the app they were typing in.
//
// What is and is not possible with public API (researched 2026-11, see docs/DEVICE_TEST.md):
//   - Going back is easy: while Scriber is in front, `UIApplication.open(<that app's URL>)`
//     brings the other app forward, and recording keeps running in the background. That is
//     what Super Whisper and VivaDicta ship (observed by the Dictus team). Done from the
//     background it fails ("neither visible nor entitled"), so it has to happen right away.
//   - Knowing *which* app to go back to is not: a keyboard extension cannot learn its host's
//     bundle id through any public API. The apps that do it (VivaDicta, Super Whisper, Dictus
//     since #538) swizzle the private `_UIKeyboardArbiterClient` and read
//     `_hostProcessIdentifier` — private API that can be rejected and can break on a new iOS.
//     Scriber does not do that.
//
// So the honest subset: the user picks the app they dictate into most, and Scriber returns
// there. With no app picked (the default) nothing happens, so the flag cannot make anything
// worse; the "◀︎" hint on the listening screen stays the fallback either way.
//
// URLs: a scheme that *names the app* resumes it where the user was; one that *names an
// action* performs it (`sms://` opens a new message). Values and the verified/unverified split
// come from the Dictus catalogue (getdictus/dictus-ios KnownAppSchemes.swift, itself ported from
// n0an/VivaDicta, MIT), which measured some entries on devices in 2026-09/10. Safari and Claude
// are deliberately absent: no URL brings them back to the page/chat the user was on.

struct AutoReturnTarget: Identifiable, Hashable, Sendable {
    /// Stable key stored in settings.
    let id: String
    let name: String
    let url: URL
    /// Measured on a device to come back where the user was (not just to open the app).
    let verified: Bool
}

enum AutoReturnCatalog {
    static let all: [AutoReturnTarget] = [
        target("line", "LINE", "line://", verified: false),
        target("messages", "訊息", "ichat://", verified: true), // sms:// would open a new message
        target("notes", "備忘錄", "mobilenotes://", verified: true),
        target("mail", "郵件", "message://", verified: true),
        target("messenger", "Messenger", "fb-messenger://", verified: false),
        target("instagram", "Instagram", "instagram://", verified: false),
        target("threads", "Threads", "barcelona://", verified: false),
        target("whatsapp", "WhatsApp", "whatsapp-consumer://", verified: true), // whatsapp:// is the Business app
        target("telegram", "Telegram", "tg://", verified: false),
        target("slack", "Slack", "slack://open", verified: true),
        target("discord", "Discord", "discord://", verified: false),
        target("gmail", "Gmail", "googlegmail://", verified: false),
        target("notion", "Notion", "notion://", verified: false),
        target("chatgpt", "ChatGPT", "com.openai.chat://", verified: true),
        target("chrome", "Chrome", "googlechrome://", verified: false),
    ]

    private static let selectedKey = "app.autoReturnTarget"

    /// The app the user chose to return to; nil = do not return automatically.
    static var selectedID: String? {
        get { AppGroup.defaults.string(forKey: selectedKey) }
        set {
            if let newValue { AppGroup.defaults.set(newValue, forKey: selectedKey) }
            else { AppGroup.defaults.removeObject(forKey: selectedKey) }
        }
    }

    static var selected: AutoReturnTarget? {
        guard let id = selectedID else { return nil }
        return all.first { $0.id == id }
    }

    private static func target(_ id: String, _ name: String, _ url: String, verified: Bool) -> AutoReturnTarget {
        AutoReturnTarget(id: id, name: name, url: URL(string: url)!, verified: verified)
    }
}
