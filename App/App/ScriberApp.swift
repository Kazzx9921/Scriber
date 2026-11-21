import SwiftUI
import ScriberCore
import ScriberShared

@main
struct ScriberApp: App {
    @State private var settings = SettingsModel.shared
    @State private var setup = SetupStatus()

    init() {
        if DebugLaunch.skipOnboarding { SettingsModel.shared.hasCompletedOnboarding = true }
        // Load the zh-TW conversion tables off the main thread so the first dictation isn't slowed down.
        Task.detached(priority: .utility) { ZhTW.prewarm() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(DictationEngine.shared)
                .environment(DictionaryStore.shared)
                .environment(HistoryStore.shared)
                .environment(settings)
                .environment(setup)
        }
    }
}
