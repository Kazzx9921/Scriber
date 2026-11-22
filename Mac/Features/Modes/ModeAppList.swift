import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An app in a mode's 自動套用 list (docs/PRD-模式.md §7.2): its name and icon from Launch Services.
struct ModeApp: Identifiable, Hashable {
    var bundleID: String
    var name: String
    var icon: NSImage?
    /// Not found on this Mac (removed since): the row says so; the bundle id still matches if it
    /// comes back.
    var installed: Bool

    var id: String { bundleID }
}

/// Names and icons for bundle ids, the running apps to pick from, and the "choose an app" panel.
@MainActor
enum ModeApps {
    private static var cache: [String: ModeApp] = [:]

    static func info(_ bundleID: String) -> ModeApp {
        if let cached = cache[bundleID] { return cached }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let app = ModeApp(bundleID: bundleID, name: name(of: url), icon: NSWorkspace.shared.icon(forFile: url.path),
                              installed: true)
            cache[bundleID] = app
            return app
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return ModeApp(bundleID: bundleID, name: running.localizedName ?? bundleID, icon: running.icon, installed: true)
        }
        return ModeApp(bundleID: bundleID, name: bundleID, icon: nil, installed: false)
    }

    /// Apps with a Dock icon that are running now, by name, minus Scriber and `excluding`.
    static func running(excluding: [String]) -> [ModeApp] {
        let skip = Set(excluding.map { $0.lowercased() } + [Bundle.main.bundleIdentifier?.lowercased() ?? ""])
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> ModeApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, !skip.contains(id.lowercased()),
                  seen.insert(id.lowercased()).inserted else { return nil }
            return ModeApp(bundleID: id, name: app.localizedName ?? id, icon: app.icon, installed: true)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 選擇 App…: an open panel in /Applications. nil when cancelled or not an app with a bundle id.
    static func choose() -> ModeApp? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "加入"
        panel.message = "選一個 App，在它裡面按主要快捷鍵時用這個模式。"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return nil }
        return ModeApp(bundleID: id, name: name(of: url), icon: NSWorkspace.shared.icon(forFile: url.path), installed: true)
    }

    private static func name(of url: URL) -> String {
        let display = FileManager.default.displayName(atPath: url.path)
        return display.hasSuffix(".app") ? String(display.dropLast(4)) : display
    }

    /// A copy of `icon` at menu size (menus draw images at their own size).
    static func menuIcon(_ icon: NSImage?) -> NSImage {
        let source = icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        let copy = source.copy() as? NSImage ?? source
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// One app under 自動套用: icon and name, a short note when it does not apply, and a remove button
/// that appears on hover.
struct ModeAppRow: View {
    let app: ModeApp
    /// Why it does not apply here ("「Email」優先"), or "沒有安裝".
    var note: String?
    let onRemove: () -> Void

    @State private var hovering = false
    @Environment(\.forcedHover) private var forcedHover

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            RowTitle(app.name, caption: note, captionIsProblem: false)
                .foregroundStyle(app.installed ? .primary : .secondary)
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering || forcedHover ? 1 : 0)
            .help("移除")
            .accessibilityLabel("移除「\(app.name)」")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 加入 App…: a bordered button that pops up the running apps, then 選擇 App… for anything else.
/// (A native menu at the pointer: SwiftUI's menu-button styles draw as plain text in this form.)
struct AddAppMenu: View {
    let existing: [String]
    let onAdd: (ModeApp) -> Void

    var body: some View {
        Button("加入 App…") {
            AppPickerMenu.show(existing: existing, onAdd: onAdd)
        }
        .buttonStyle(.bordered)
        .help("在這個 App 裡按主要快捷鍵時用這個模式")
    }
}

/// The pop-up behind 加入 App….
@MainActor
final class AppPickerMenu: NSObject {
    private let apps: [ModeApp]
    private let onAdd: (ModeApp) -> Void
    /// Kept alive while the menu (and the open panel after it) is up.
    private static var current: AppPickerMenu?

    private init(apps: [ModeApp], onAdd: @escaping (ModeApp) -> Void) {
        self.apps = apps
        self.onAdd = onAdd
    }

    static func show(existing: [String], onAdd: @escaping (ModeApp) -> Void) {
        let picker = AppPickerMenu(apps: ModeApps.running(excluding: existing), onAdd: onAdd)
        current = picker
        picker.menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !apps.isEmpty {
            menu.addItem(.sectionHeader(title: "正在執行"))
            for (index, app) in apps.enumerated() {
                let item = NSMenuItem(title: app.name, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.image = ModeApps.menuIcon(app.icon)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let choose = NSMenuItem(title: "選擇 App…", action: #selector(chooseApp), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)
        return menu
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard apps.indices.contains(item.tag) else { return }
        onAdd(apps[item.tag])
        Self.current = nil
    }

    @objc private func chooseApp() {
        // After the menu has closed: the open panel is modal.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let app = ModeApps.choose() { self.onAdd(app) }
                Self.current = nil
            }
        }
    }
}
