import SwiftUI
import ScriberCore
import ScriberShared

struct RootView: View {
    @Environment(DictationEngine.self) private var engine
    @Environment(SettingsModel.self) private var settings
    @Environment(SetupStatus.self) private var setup
    @Environment(DictionaryStore.self) private var dictionary
    @Environment(HistoryStore.self) private var history
    @Environment(\.scenePhase) private var scenePhase

    @State private var showListening = DebugLaunch.listening
    /// When the scene last became active. Tells "opened by the keyboard from another app"
    /// apart from "the keyboard was used inside Scriber itself" (no app switch, no back chip).
    @State private var activeSince: Date?

    var body: some View {
        ZStack {
            content
            if showListening {
                ListeningView(isDemo: DebugLaunch.listening) {
                    showListening = false
                }
                .zIndex(1)
            }
        }
        .onOpenURL(perform: open)
        .onChange(of: scenePhase) { _, phase in
            DiagLog.log("app", "scene \(String(describing: phase))")
            switch phase {
            case .active:
                if activeSince == nil { activeSince = Date() }
                engine.refreshMicPermission()
                setup.refresh()
                settings.refreshKeys()
                settings.reloadShared()
            case .background:
                activeSince = nil
                // The user went back to the other app; next time show the normal app.
                if !DebugLaunch.listening { showListening = false }
            default:
                break
            }
        }
        .task {
            engine.refreshMicPermission()
            setup.refresh()
            if DebugLaunch.demoData { DemoData.seed(dictionary: dictionary, history: history) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let step = DebugLaunch.onboardingStep {
            OnboardingView(initialStep: step)
        } else if settings.hasCompletedOnboarding {
            MainTabView()
        } else {
            OnboardingView()
        }
    }

    private func open(_ url: URL) {
        let alreadyInApp = activeSince.map { Date().timeIntervalSince($0) > 1 } ?? false
        _ = engine.handle(url: url, openedFromOtherApp: !alreadyInApp)
        if url.scheme == AppGroup.urlScheme, url.host == "settings" {
            // The keyboard's "needs setup" feedback opens the app here.
            NotificationCenter.default.post(name: .scriberOpenSettings, object: nil)
            return
        }
        guard url.scheme == AppGroup.urlScheme, url.host == "session" else { return }

        if alreadyInApp {
            // Keyboard used inside Scriber (e.g. onboarding try-it field): nothing to go back to.
            Haptics.tap()
            return
        }
        // Seen many times a day: appear instantly, no slide-in.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showListening = true }
    }
}

extension Notification.Name {
    static let scriberOpenSettings = Notification.Name("ScriberOpenSettings")
}

enum AppTab: String, Hashable {
    case home, dictionary, history, settings
}

struct MainTabView: View {
    @State private var tab = AppTab(rawValue: DebugLaunch.tab ?? "") ?? .home

    var body: some View {
        tabs.onReceive(NotificationCenter.default.publisher(for: .scriberOpenSettings)) { _ in
            tab = .settings
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $tab) {
                Tab("首頁", systemImage: "waveform", value: AppTab.home) { HomeView() }
                Tab("字典", systemImage: "character.book.closed", value: AppTab.dictionary) { DictionaryView() }
                Tab("歷史", systemImage: "clock.arrow.circlepath", value: AppTab.history) { HistoryView() }
                Tab("設定", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            }
        } else {
            TabView(selection: $tab) {
                HomeView()
                    .tabItem { Label("首頁", systemImage: "waveform") }
                    .tag(AppTab.home)
                DictionaryView()
                    .tabItem { Label("字典", systemImage: "character.book.closed") }
                    .tag(AppTab.dictionary)
                HistoryView()
                    .tabItem { Label("歷史", systemImage: "clock.arrow.circlepath") }
                    .tag(AppTab.history)
                SettingsView()
                    .tabItem { Label("設定", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
        }
    }
}
