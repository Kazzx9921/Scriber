import Foundation
import Observation
import UIKit

/// Things the app can only learn by asking the system: is the Scriber keyboard added?
/// Refresh whenever the app becomes active (the user may have just come back from Settings).
@MainActor
@Observable
final class SetupStatus {
    static let keyboardBundleID = "com.geekaz.Scriber.Keyboard"

    private(set) var isKeyboardAdded = false

    init() { refresh() }

    func refresh() {
        let added = Self.detectKeyboard()
        if added != isKeyboardAdded { isKeyboardAdded = added }
    }

    // TODO(contract request → agent C): the app cannot see whether 允許完整取用 is on.
    // If the keyboard wrote a flag (e.g. `hasFullAccess` + timestamp) into AppGroup.defaults
    // whenever it loads, the app could confirm Full Access here instead of just reminding the user.

    private static func detectKeyboard() -> Bool {
        // `UITextInputMode.identifier` is not public API, so read it defensively through KVC.
        let selector = NSSelectorFromString("identifier")
        for mode in UITextInputMode.activeInputModes where mode.responds(to: selector) {
            if let id = mode.value(forKey: "identifier") as? String, id.hasPrefix(keyboardBundleID) {
                return true
            }
        }
        // Fallback: the global keyboard list, visible to apps through the standard defaults.
        if let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] {
            return keyboards.contains { $0.hasPrefix(keyboardBundleID) }
        }
        return false
    }
}
