import AppKit
import SwiftUI
import ScriberShared

/// Menu bar app (LSUIElement: no Dock icon). Settings and first-run windows are AppKit-managed
/// (`WindowManager`); the floating HUD is a non-activating panel (`HUDController`).
@main
struct ScriberMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = DictationController.shared
    @State private var settings = MacSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(controller)
                .environment(settings)
        } label: {
            Image(systemName: controller.presentedMenuBarSymbol)
                .accessibilityLabel("Scriber")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if quitIfAlreadyRunning() { return }
            EditMenu.installIfNeeded(settingsTarget: self)
            DictationController.shared.start()
            _ = EngineStatus.live // start mirroring for the windows
            if !MacSettings.shared.hasCompletedOnboarding {
                WindowManager.shared.showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            DictationController.shared.shutdown()
        }
    }

    /// Opening the app again (Finder, Spotlight) while it runs shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            WindowManager.shared.showMain()
        }
        return false
    }

    /// ⌘, while a Scriber window is in front.
    @objc func openSettings(_ sender: Any?) {
        MainActor.assumeIsolated {
            WindowManager.shared.showMain(.settings)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Two copies (e.g. a debug build and an installed one) would both catch the hotkey.
    @MainActor
    private func quitIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != me }
        guard !others.isEmpty else { return false }
        DiagLog.log("app", "another copy is already running (pid \(others.map { String($0.processIdentifier) }.joined(separator: ","))) → quitting this one")
        NSApp.terminate(nil)
        return true
    }
}

/// An accessory app has no visible menu bar, but ⌘C / ⌘V / ⌘A in its own text fields (API key,
/// 試一次) and ⌘, still go through the main menu's key equivalents. Make sure they exist.
enum EditMenu {
    @MainActor
    static func installIfNeeded(settingsTarget: AnyObject) {
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        if NSApp.mainMenu == nil { NSApp.mainMenu = mainMenu }
        installSettingsItem(in: mainMenu, target: settingsTarget)
        if mainMenu.items.contains(where: { item in item.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } ?? false }) {
            return
        }
        let editItem = NSMenuItem(title: "編輯", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "編輯")
        edit.addItem(withTitle: "還原", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        DiagLog.log("app", "edit menu installed")
    }

    /// ⌘, → 設定 in the application menu (replacing SwiftUI's item if it has one).
    @MainActor
    private static func installSettingsItem(in mainMenu: NSMenu, target: AnyObject) {
        let appMenu: NSMenu
        if let first = mainMenu.items.first?.submenu {
            appMenu = first
        } else {
            let item = NSMenuItem(title: "Scriber", action: nil, keyEquivalent: "")
            appMenu = NSMenu(title: "Scriber")
            item.submenu = appMenu
            mainMenu.insertItem(item, at: 0)
        }
        for item in appMenu.items where item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command {
            appMenu.removeItem(item)
        }
        let settings = NSMenuItem(title: "設定…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.insertItem(settings, at: min(1, appMenu.items.count))
    }
}
