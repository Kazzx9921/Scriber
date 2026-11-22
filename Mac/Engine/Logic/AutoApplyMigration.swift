import Foundation
import ScriberCore
import ScriberShared

/// 自動套用的 App starts working in M3 (docs/PRD-模式.md §7.2). The shipped Email mode lists Apple
/// Mail, and earlier builds already wrote that into `modes.json` without acting on it. Switching it
/// on by itself would change what the main hotkey does in Mail for people who already use Scriber
/// (Email runs the AI with the Email prompt), so:
/// - a new install keeps Email → Mail, as the PRD ships it;
/// - an existing install gets Mail taken off Email, once; turning it on is one click in the mode
///   (and 還原預設 brings it back).
/// Runs once per install; a list the user has edited since is never touched again.
enum AutoApplyMigration {
    static let doneKey = "mac.modes.autoApplyIntroduced"
    static let mailBundleID = "com.apple.mail"

    enum Outcome: Equatable {
        /// Already done on this install.
        case alreadyDone
        /// New install: the shipped lists stay.
        case keptShipped
        /// Existing install: Mail taken off Email.
        case heldBack
        /// Existing install, but Email did not list Mail (nothing to change).
        case nothingToHold
        /// The store refused the change; not marked done, tried again at the next launch.
        case failed
    }

    /// Any sign that Scriber was used before this launch.
    static func isExistingInstall(onboardingDone: Bool, modesMigrationVersion: Int, hasAnyKey: Bool) -> Bool {
        onboardingDone || modesMigrationVersion > 0 || hasAnyKey
    }

    @discardableResult
    static func runIfNeeded(store: ModeStore, defaults: UserDefaults, existingInstall: Bool,
                            log: (String) -> Void = { _ in }) -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return .alreadyDone }
        let outcome: Outcome
        if !existingInstall {
            outcome = .keptShipped
        } else if var email = store.mode(id: BuiltInModeID.email.rawValue),
                  email.trigger.appBundleIDs.contains(where: { $0.lowercased() == mailBundleID }) {
            email.trigger.appBundleIDs.removeAll { $0.lowercased() == mailBundleID }
            do {
                try store.update(email)
                outcome = .heldBack
            } catch {
                log("auto-apply intro failed \(error)")
                return .failed
            }
        } else {
            outcome = .nothingToHold
        }
        defaults.set(true, forKey: doneKey)
        switch outcome {
        case .heldBack: log("auto-apply intro: existing install, \(mailBundleID) taken off \(BuiltInModeID.email.rawValue)")
        case .keptShipped: log("auto-apply intro: new install, shipped app lists kept")
        case .nothingToHold: log("auto-apply intro: existing install, nothing to change")
        case .alreadyDone, .failed: break
        }
        return outcome
    }
}
