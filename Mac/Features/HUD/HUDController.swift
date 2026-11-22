import AppKit
import SwiftUI
import ScriberShared

/// A panel that can never become key or main, never activates Scriber, joins every Space
/// (including full-screen apps) and ignores the mouse unless a clickable message is shown.
/// Focus therefore always stays in the app the user is typing in, which ⌘V depends on.
final class HUDPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a non-key panel reach the SwiftUI content (retry / open settings).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the pill near the bottom centre of the screen the user is working on.
///
/// The transparent panel is sized for its content: the standard size for the pill, a larger one
/// only while a real-time recording may show text (a clickable message makes the whole panel take
/// the mouse, so it must not stay large). Resizes keep the bottom centre fixed, where the pill is.
@MainActor
final class HUDController {
    private static let panelSize = NSSize(width: 460, height: 76)
    private static let livePanelSize = NSSize(width: HUDView.liveWidth + 80, height: 160)
    private static let bottomMargin: CGFloat = 36

    private let model = HUDModel()
    private var panel: HUDPanel?
    private var hideWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?

    /// `live`: a real-time session is running; the pill grows when `updateLiveText` brings text.
    /// `symbol`: the mode's icon (nil: nothing, plain 聽寫); `badge` (translate language) wins over it.
    func showRecording(mode: DictationMode, badge: String?, symbol: String? = nil, live: Bool = false,
                       level: @escaping () -> Float) {
        model.levels.reset()
        model.levels.provider = level
        model.liveEnabled = live
        model.liveCommitted = ""
        model.livePartial = ""
        show(.recording(mode, badge: badge, symbol: symbol), onClick: nil, reposition: true,
             size: live ? Self.livePanelSize : Self.panelSize)
    }

    /// A short hint shown inside the recording pill for a moment (e.g. "press Esc again").
    func flashRecordingHint(_ text: String, for seconds: TimeInterval) {
        guard case .recording = model.state else { return }
        model.recordingHint = text
        hintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.recordingHint = nil }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private var hintWork: DispatchWorkItem?

    /// Latest recognized text (already converted for display). Ignored unless a live recording is shown.
    func updateLiveText(committed: String, partial: String) {
        guard model.liveEnabled, case .recording = model.state else { return }
        if model.liveCommitted != committed { model.liveCommitted = committed }
        if model.livePartial != partial { model.livePartial = partial }
    }

    /// The real-time session ended early: back to the plain pill for the rest of the recording.
    func endLiveText() {
        guard model.liveEnabled else { return }
        model.liveEnabled = false
        model.liveCommitted = ""
        model.livePartial = ""
        scheduleShrink()
    }

    func showProcessing(mode: DictationMode, symbol: String? = nil) {
        show(.processing(mode, symbol: symbol), onClick: nil, reposition: false)
    }

    /// Auto-dismisses after `feedback.duration`.
    func showFeedback(_ feedback: HUDFeedback, onClick: (() -> Void)?) {
        show(.feedback(feedback), onClick: onClick, reposition: false)
        if feedback.isProblem { model.shakes += 1 }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .feedback(let shown) = self.model.state, shown == feedback else { return }
                self.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + feedback.duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        model.onClick = nil
        model.levels.provider = nil
        clearLive()
        model.state = .hidden
        guard let panel, panel.isVisible else { return }
        panel.ignoresMouseEvents = true
        // Let the pill fade out, then take the window off screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.state == .hidden else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// `size` nil: keep the current size, but go back to the standard one shortly (after the panel's
    /// content has animated) unless the new state is a live recording.
    private func show(_ state: HUDState, onClick: (() -> Void)?, reposition: Bool, size: NSSize? = nil) {
        hideWork?.cancel()
        hideWork = nil
        let panel = panel ?? makePanel()
        if case .recording = state {} else { clearLive() }
        if reposition || !panel.isVisible {
            shrinkWork?.cancel()
            place(panel, size: size ?? Self.panelSize)
        } else if let size {
            shrinkWork?.cancel()
            resize(panel, to: size)
        } else if panel.frame.size != Self.panelSize {
            scheduleShrink()
        }
        model.onClick = onClick
        model.recordingHint = nil
        hintWork?.cancel()
        model.state = state
        panel.ignoresMouseEvents = onClick == nil
        if !panel.isVisible {
            // Never makeKey / activate: the user's app keeps keyboard focus.
            panel.orderFrontRegardless()
        }
    }

    private func clearLive() {
        model.liveEnabled = false
        if !model.liveCommitted.isEmpty { model.liveCommitted = "" }
        if !model.livePartial.isEmpty { model.livePartial = "" }
    }

    private func scheduleShrink() {
        shrinkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !self.model.liveEnabled else { return }
                self.resize(panel, to: Self.panelSize)
            }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Bottom centre stays where it is, so the bottom-aligned pill does not move.
    private func resize(_ panel: HUDPanel, to size: NSSize) {
        let frame = panel.frame
        guard frame.size != size else { return }
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(size: Self.panelSize)
        let host = FirstMouseHostingView(rootView: HUDView(model: model))
        // Fixed-size transparent panel: SwiftUI must not resize it to the pill (or to nothing).
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func place(_ panel: HUDPanel, size: NSSize) {
        guard let screen = FocusInfo.activeScreen() else {
            resize(panel, to: size)
            return
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + Self.bottomMargin - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}
