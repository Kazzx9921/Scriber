import Foundation
import UIKit

/// App-only state about the standby experiment that must survive relaunches. Kept in the app's
/// own defaults: the keyboard never needs it, and `AppSettings` is the shared contract.
enum StandbyMemory {
    /// iOS refused to start the microphone from the background in the `.outputOnly` standby.
    /// While this is set (for the same iOS version), `.outputOnly` behaves like `.off` so every
    /// later dictation does not pay for the same refusal again. Cleared by changing the mode,
    /// by "再試一次" in Settings, or by an iOS update.
    struct Refusal: Codable, Equatable {
        var at: Date
        var osVersion: String
        /// Error domain/code only, e.g. "domain=NSOSStatusErrorDomain code=561145187('!rec')".
        var error: String
    }

    private static let refusalKey = "standby.outputOnlyRefusal"
    private static let keepAliveCategoryKey = "standby.keepAliveCategory"
    private static var defaults: UserDefaults { .standard }

    @MainActor
    static var outputOnlyRefusal: Refusal? {
        get {
            guard let data = defaults.data(forKey: refusalKey),
                  let refusal = try? JSONDecoder().decode(Refusal.self, from: data),
                  refusal.osVersion == UIDevice.current.systemVersion else { return nil }
            return refusal
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: refusalKey)
            } else {
                defaults.removeObject(forKey: refusalKey)
            }
        }
    }

    /// Developer knob (診斷紀錄 → ⋯): the idle category of the `.outputOnly` standby.
    static var keepAliveCategory: AudioRecorder.KeepAliveCategory {
        get { AudioRecorder.KeepAliveCategory(rawValue: defaults.string(forKey: keepAliveCategoryKey) ?? "") ?? .playback }
        set { defaults.set(newValue.rawValue, forKey: keepAliveCategoryKey) }
    }
}
