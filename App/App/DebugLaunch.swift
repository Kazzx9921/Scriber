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
    /// Open a secondary screen on launch: apiKey | keyboardSetup | experimental | customEngine |
    /// modes | mode | modeIcon | modePrompt | prompts | prompt | promptNew (settings tab),
    /// dictionaryEditor (dictionary tab), historyDetail (history tab).
    static var screen: String? { string("ScriberScreen") }
    /// The mode `-ScriberScreen mode|modeIcon|modePrompt` opens (default 聽寫).
    static var modeID: String? { string("ScriberModeID") }
    /// Scrolls the mode editor to its 輸出 section on launch (`-ScriberScrollTo output`).
    static var scrollTarget: String? { string("ScriberScrollTo") }
    /// The prompt `-ScriberScreen prompt` opens (default 預設).
    static var promptID: String? { string("ScriberPromptID") }
    /// Seed sample modes and a prompt (a custom 「會議重點」 that only copies, a custom prompt)
    /// when there are no custom ones yet. Writes the App Group files like the user would.
    static var demoModes: Bool { flag("ScriberDemoModes") }
    /// Show the "已開始聆聽" screen with a fake active session.
    static var listening: Bool { flag("ScriberListening") }
    /// Display-only "setup is finished" state for store screenshots: Home hides the setup steps
    /// and Settings shows ElevenLabs + Groq keys as saved. Nothing is stored in the Keychain and
    /// no permission is requested; recording still needs real permission and keys.
    static var demoReady: Bool { flag("ScriberDemoReady") }

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
