import AppKit
import SwiftUI
import ScriberShared

/// The main window, the first-run window and the 自動貼上 window, managed with AppKit so an
/// accessory (menu bar) app can bring them to the front reliably. They are the only Scriber UI that
/// takes focus, and only when the user opens them.
///
/// All three use a transparent, title-less title bar with the content running under it (the
/// modern macOS look); the traffic lights stay.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    let navigation = MainNavigation()

    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var autoPasteWindow: NSWindow?

    static let mainDefaultSize = NSSize(width: 980, height: 700)
    static let mainMinimumSize = NSSize(width: 780, height: 540)

    /// 打開 Scriber… / ⌘, / clicks on HUD messages that need a setting.
    func showMain(_ section: MainSection? = nil) {
        if let section { navigation.section = section }
        if mainWindow == nil {
            let view = MainWindowView()
                .environment(navigation)
                .environment(EngineStatus.live)
                .environment(MacSettings.shared)
            let window = makeWindow(title: "Scriber", size: Self.mainDefaultSize, resizable: true, content: view)
            window.contentMinSize = Self.mainMinimumSize
            window.setFrameAutosaveName("ScriberMainWindow")
            mainWindow = window
        }
        present(mainWindow)
        DiagLog.log("app", "main window opened section=\(navigation.section.rawValue)")
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(onFinish: { [weak self] in self?.onboardingWindow?.close() })
                .environment(EngineStatus.live)
                .environment(MacSettings.shared)
            onboardingWindow = makeWindow(title: "歡迎使用 Scriber", size: OnboardingView.size, resizable: false, content: view)
        }
        present(onboardingWindow)
        DiagLog.log("app", "onboarding opened")
    }

    /// 開啟自動貼上 from 首頁, 設定 and the menu.
    func showAutoPaste() {
        if autoPasteWindow == nil {
            let view = AutoPasteWindowView(onClose: { [weak self] in self?.autoPasteWindow?.close() })
                .environment(EngineStatus.live)
                .environment(MacSettings.shared)
            autoPasteWindow = makeWindow(title: "開啟自動貼上", size: AutoPasteWindowView.size, resizable: false, content: view)
        }
        present(autoPasteWindow)
        DiagLog.log("app", "auto-paste window opened ax=\(Permissions.isAccessibilityTrusted)")
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, resizable: Bool, content: Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title // still used by Mission Control, the Window menu and VoiceOver
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = !resizable
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: content)
        // The window, not SwiftUI's ideal size, decides the size (no jumping when a page changes).
        controller.sizingOptions = resizable ? [] : [.minSize]
        window.contentViewController = controller
        window.setContentSize(size)
        if !resizable { window.standardWindowButton(.zoomButton)?.isEnabled = false }
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        // Opened by the user from the menu bar, so activation is allowed; orderFrontRegardless
        // still shows the window if macOS declines to activate an accessory app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            // Closing the first-run window counts as done; Home lists what is still missing.
            MacSettings.shared.hasCompletedOnboarding = true
            DiagLog.log("app", "onboarding closed")
            onboardingWindow = nil
        }
        if window === autoPasteWindow {
            DiagLog.log("app", "auto-paste window closed ax=\(Permissions.isAccessibilityTrusted)")
            autoPasteWindow = nil
        }
        if window === mainWindow {
            // A key capture in progress must not leave the hotkey paused.
            DictationController.shared.pauseHotkey(false)
        }
    }
}
