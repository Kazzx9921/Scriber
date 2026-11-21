import UIKit
import ScriberShared

/// Thin wrapper over UIKit feedback generators that respects the user's 觸覺回饋 setting.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let notification = UINotificationFeedbackGenerator()

    private static var isEnabled: Bool { AppSettings.shared.hapticsEnabled }

    /// Small confirmation, e.g. copy or picker change.
    static func tap() {
        guard isEnabled else { return }
        light.impactOccurred()
    }

    /// Recording started.
    static func recordStart() {
        guard isEnabled else { return }
        medium.impactOccurred()
    }

    /// Recording stopped / sent.
    static func recordStop() {
        guard isEnabled else { return }
        soft.impactOccurred()
    }

    static func success() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    static func warning() {
        guard isEnabled else { return }
        notification.notificationOccurred(.warning)
    }

    static func error() {
        guard isEnabled else { return }
        notification.notificationOccurred(.error)
    }
}
