import Foundation

/// DEBUG-only launch arguments used for layout review and screenshots, e.g.
/// `xcrun simctl launch <udid> com.geekaz.Scriber -ScriberTab settings -ScriberDemo YES`.
/// Every accessor returns the neutral value in release builds.
enum DebugLaunch {
    /// Seed sample try-area results, dictionary entries and history (stores must be implemented).
    static var demoData: Bool { flag("ScriberDemo") }
    /// Show onboarding at this page index regardless of the stored flag.
    static var onboardingStep: Int? { int("ScriberOnboarding") }
    /// Mark onboarding as done before the first frame.
    static var skipOnboarding: Bool { flag("ScriberSkipOnboarding") }
    /// Initial tab: home | dictionary | history | settings.
    static var tab: String? { string("ScriberTab") }
    /// Open a secondary screen on launch: apiKey | keyboardSetup | experimental | customEngine
    /// (settings tab), dictionaryEditor (dictionary tab), historyDetail (history tab).
    static var screen: String? { string("ScriberScreen") }
    /// Show the "已開始聆聽" screen with a fake active session.
    static var listening: Bool { flag("ScriberListening") }

    private static func flag(_ key: String) -> Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: key)
        #else
        false
        #endif
    }

    private static func string(_ key: String) -> String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: key)
        #else
        nil
        #endif
    }

    private static func int(_ key: String) -> Int? {
        #if DEBUG
        UserDefaults.standard.object(forKey: key) == nil ? nil : UserDefaults.standard.integer(forKey: key)
        #else
        nil
        #endif
    }
}
