import AppKit
import SwiftUI
import XCTest

/// Renders SwiftUI content off-screen to PNG files for design review.
///
/// The content is hosted in an `NSHostingView` inside an `NSWindow` that is never ordered front,
/// laid out at a realistic size, and captured with `cacheDisplay(in:to:)` (which also draws
/// AppKit-backed controls, unlike `ImageRenderer`). With `chrome: true` the window's frame view is
/// captured too (title bar, traffic lights).
///
/// Known limits of off-screen capture (found by probing):
/// - Liquid Glass (`glassEffect`, `.glass` button styles) draws nothing, so renders force the
///   pre-macOS 26 fallback styles (`GlassSupport.forceFallback`).
/// - System controls draw in their inactive-window style (grey switches and prominent buttons):
///   telling SwiftUI the window is active switches it to a GPU path the capture cannot read.
@MainActor
enum SnapshotRenderer {
    enum Appearance: String, CaseIterable {
        case light, dark

        var nsAppearance: NSAppearance? {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)
        }
    }

    /// `$SCRIBER_SNAPSHOT_DIR` (pass `TEST_RUNNER_SCRIBER_SNAPSHOT_DIR` to xcodebuild), else a
    /// folder in the temporary directory.
    static var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SCRIBER_SNAPSHOT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("scriber-mac-shots", isDirectory: true)
    }

    private static var didPrepareApp = false

    /// An NSApplication must exist; `.prohibited` keeps the test process out of the Dock and
    /// never activates it.
    static func prepareApp() {
        guard !didPrepareApp else { return }
        didPrepareApp = true
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        GlassSupport.forceFallback = true
    }

    /// Renders `content` at `size` (content size, points) into `<name>-<appearance>.png`.
    @discardableResult
    static func render<Content: View>(_ name: String, size: CGSize, appearance: Appearance,
                                      chrome: Bool = true, settle: TimeInterval = 0.4,
                                      @ViewBuilder content: () -> Content) throws -> URL {
        prepareApp()
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance.nsAppearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Without the frame view nothing paints the window background (sheets, popovers).
        // Hosted like the app's windows (`WindowManager`): through an NSHostingController, which
        // also gives SwiftUI the window toolbar, so safe areas match the real app.
        let controller = NSHostingController(rootView: content()
            .background(chrome ? Color.clear : Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(size)
        let host = controller.view

        // Let SwiftUI run onAppear/tasks and settle animations.
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }

        let target: NSView = chrome ? (host.superview ?? host) : host
        target.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bounds = target.bounds
        guard let rep = target.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw NSError(domain: "Snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "no bitmap rep"])
        }
        target.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Snapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "png encoding failed"])
        }
        let folder = outputDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name)-\(appearance.rawValue).png")
        try data.write(to: url)
        window.contentView = nil
        window.close()
        return url
    }

    /// Both appearances.
    static func renderBoth<Content: View>(_ name: String, size: CGSize, chrome: Bool = true,
                                          @ViewBuilder content: () -> Content) throws {
        for appearance in Appearance.allCases {
            try render(name, size: size, appearance: appearance, chrome: chrome, content: content)
        }
    }
}

/// Reports itself as the key window (so focus-dependent drawing behaves) without ever being shown.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
