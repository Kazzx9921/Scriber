import SwiftUI
import UIKit
import ScriberShared

/// Coordinate space of the whole keyboard view, shared by the translate key's gesture and the
/// popup overlay so the popup is drawn exactly where the finger is hit-tested.
enum KeyboardSpace {
    static let name = "ScriberKeyboardSpace"
}

// MARK: - Popup geometry

/// Where the long-press language popup sits, in `KeyboardSpace`. One value both draws the popup
/// and hit-tests the finger.
///
/// Placement: a single row of cells (one per quick language) whose first cell sits over the
/// translate key and the rest extend to the right, over the mic pill; vertically just above the
/// key, overlapping its top edge, and pushed down when the keyboard is too short. Portrait
/// (176 pt, key at y 43–85): panel y 3–53, finger at y 64. Landscape (140 pt, key at y 29–71):
/// panel y 3–43, finger at y 50. Always clamped inside the keyboard bounds, which an extension
/// cannot draw outside of.
struct TranslatePopupLayout: Equatable {
    var panel: CGRect
    var cells: [CGRect]
    var cellSize: CGSize
    var padding: CGFloat
    /// Area in which the finger selects a cell (by x only); outside it, releasing cancels.
    var zone: CGRect

    static let margin: CGFloat = 3

    static func make(key: CGRect, bounds: CGSize, count: Int, compact: Bool) -> TranslatePopupLayout {
        let cellSize = compact ? CGSize(width: 62, height: 32) : CGSize(width: 66, height: 40)
        let padding: CGFloat = compact ? 3 : 4
        let width = CGFloat(max(count, 1)) * cellSize.width + 2 * padding
        let height = cellSize.height + 2 * padding
        let x = clamp(key.minX - padding, low: margin, high: bounds.width - margin - width)
        let y = clamp(key.minY + 6 - height, low: margin, high: bounds.height - margin - height)
        let panel = CGRect(x: x, y: y, width: width, height: height)
        let cells = (0..<count).map { index in
            CGRect(x: x + padding + CGFloat(index) * cellSize.width, y: y + padding,
                   width: cellSize.width, height: cellSize.height)
        }
        // Generous vertically (a finger sliding sideways along the key row still selects), a
        // little wider than the panel horizontally.
        let zoneTop = panel.minY - 40
        let zoneBottom = max(panel.maxY + 16, key.maxY + 10)
        let zone = CGRect(x: panel.minX - 16, y: zoneTop, width: panel.width + 32, height: zoneBottom - zoneTop)
        return TranslatePopupLayout(panel: panel, cells: cells, cellSize: cellSize, padding: padding, zone: zone)
    }

    /// The cell under the finger, nil outside the zone.
    func index(at point: CGPoint) -> Int? {
        guard !cells.isEmpty, zone.contains(point) else { return nil }
        // Cells are contiguous: the first one whose right edge is past the finger. The outer
        // cells extend to the zone's edges.
        return cells.firstIndex { point.x < $0.maxX } ?? cells.count - 1
    }

    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}

// MARK: - Gesture state machine

/// The translate key's touch handling, kept out of the view so the key and the popup overlay
/// (drawn at the root, above everything) share it.
///
/// - Tap (released before `holdDuration`, finger still near the key): `onTap` (translate on/off).
/// - Hold `holdDuration`: the popup opens with nothing highlighted.
///   - Drag: once the finger has moved `armDistance` from where the popup opened, the cell under
///     it is highlighted (a selection haptic per change). Release on a cell chooses it; release
///     outside the zone cancels.
///   - Release without moving: the popup stays open ("sticky") and its cells are tapped instead;
///     a tap anywhere else dismisses it.
@MainActor
@Observable
final class TranslatePicker {
    enum Phase: Equatable {
        case closed
        /// Open, finger still down on the key.
        case tracking
        /// Open after a long press without a drag; waiting for a tap.
        case sticky
    }

    enum Feedback { case opened, highlight }

    static let holdDuration: TimeInterval = 0.2
    /// Movement that turns "holding" into "dragging" (larger than a resting finger's jitter).
    static let armDistance: CGFloat = 10
    /// Moving farther than this from the touch-down point cancels the tap (like system keys).
    static let tapSlop: CGFloat = 28

    private(set) var phase: Phase = .closed
    private(set) var highlighted: Int?
    private(set) var options: [TranslateLanguage] = []
    private(set) var layout: TranslatePopupLayout?
    private(set) var isPressed = false

    /// Reported by the views; only read when the popup opens, so not observed.
    @ObservationIgnored var keyFrame: CGRect = .zero
    @ObservationIgnored var containerSize: CGSize = .zero

    // Wired by KeyboardModel.
    @ObservationIgnored var onTap: () -> Void = {}
    /// Options and orientation, or nil to refuse (the model then explains why).
    @ObservationIgnored var openContext: () -> (languages: [TranslateLanguage], compact: Bool)? = { nil }
    @ObservationIgnored var onChoose: (TranslateLanguage, String) -> Void = { _, _ in }
    @ObservationIgnored var onFeedback: (Feedback) -> Void = { _ in }

    private struct Touch {
        var id: Int
        var startPoint: CGPoint
        var last: CGPoint
        var openedAt: CGPoint?
        var armed = false
        /// Moved off the key, the hold was refused, or the popup was closed under the finger:
        /// lifting the finger does nothing.
        var spent = false
    }

    @ObservationIgnored private var touch: Touch?
    @ObservationIgnored private var touchCounter = 0
    @ObservationIgnored private var holdWork: DispatchWorkItem?

    // MARK: Touch events (KeyboardSpace coordinates)

    func touchChanged(to point: CGPoint) {
        guard var current = touch else {
            begin(at: point)
            return
        }
        current.last = point
        if phase == .tracking, let layout {
            if !current.armed, let origin = current.openedAt, Self.distance(point, origin) > Self.armDistance {
                current.armed = true
            }
            touch = current
            if current.armed { setHighlight(layout.index(at: point)) }
            return
        }
        if !current.spent, Self.distance(point, current.startPoint) > Self.tapSlop {
            current.spent = true
            holdWork?.cancel()
            isPressed = false
        }
        touch = current
    }

    func touchEnded(at point: CGPoint) {
        guard let current = touch else { return }
        touch = nil
        holdWork?.cancel()
        holdWork = nil
        isPressed = false
        switch phase {
        case .tracking:
            if current.armed, let index = layout?.index(at: point) {
                choose(index, via: "drag")
            } else if !current.armed {
                phase = .sticky
                highlighted = nil
            } else {
                close(reason: "released-outside")
            }
        case .closed:
            if !current.spent { onTap() }
        case .sticky:
            break
        }
    }

    /// The gesture's state was reset. After a normal lift `touchEnded` has already run; if it
    /// has not shortly after, the system cancelled the touch.
    func touchStateReset() {
        guard let id = touch?.id else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.touch?.id == id else { return }
                self.cancelTouch(reason: "touch-cancelled")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// The key left the screen (recording started, text got selected…).
    func keyDisappeared() {
        cancelTouch(reason: "key-hidden")
        close(reason: "key-hidden")
    }

    /// A cell tapped while the popup is sticky (or activated by VoiceOver).
    func tapOption(_ index: Int) {
        choose(index, via: "popup-tap")
    }

    func close(reason: String) {
        holdWork?.cancel()
        holdWork = nil
        if touch != nil { touch?.spent = true }
        isPressed = false
        guard phase != .closed else { return }
        if reason != "chosen" { KBLog.log("translate picker closed reason=\(reason)") }
        phase = .closed
        highlighted = nil
        layout = nil
    }

    /// Keyboard hidden: forget everything.
    func reset() {
        touch = nil
        close(reason: "keyboard-hidden")
    }

    // MARK: Private

    private func begin(at point: CGPoint) {
        if phase == .sticky { close(reason: "key-touched") }
        touchCounter += 1
        touch = Touch(id: touchCounter, startPoint: point, last: point)
        isPressed = true
        let id = touchCounter
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.holdElapsed(touchID: id) }
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: work)
    }

    private func holdElapsed(touchID: Int) {
        guard var current = touch, current.id == touchID, !current.spent, phase == .closed else { return }
        guard keyFrame != .zero, containerSize != .zero, let context = openContext(), !context.languages.isEmpty else {
            current.spent = true // refused (e.g. translate unavailable, already explained)
            touch = current
            isPressed = false
            return
        }
        options = context.languages
        layout = TranslatePopupLayout.make(key: keyFrame, bounds: containerSize, count: options.count,
                                           compact: context.compact)
        highlighted = nil
        current.openedAt = current.last
        touch = current
        phase = .tracking
        onFeedback(.opened)
    }

    private func setHighlight(_ index: Int?) {
        guard index != highlighted else { return }
        highlighted = index
        if index != nil { onFeedback(.highlight) }
    }

    private func choose(_ index: Int, via: String) {
        guard options.indices.contains(index) else {
            close(reason: "bad-index")
            return
        }
        let language = options[index]
        close(reason: "chosen")
        onChoose(language, via)
    }

    private func cancelTouch(reason: String) {
        guard touch != nil else { return }
        touch = nil
        holdWork?.cancel()
        holdWork = nil
        isPressed = false
        if phase == .tracking { close(reason: reason) }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

// MARK: - The key

/// Round key left of the mic. Off: the translate glyph. On: the language's short label in the
/// inverted "on" style. Unavailable (AI polish off or its key missing): dimmed glyph; tapping
/// explains in the mic pill.
struct TranslateKey: View {
    let model: KeyboardModel

    @Environment(\.colorScheme) private var scheme
    @GestureState private var touching = false

    var body: some View {
        let picker = model.translatePicker
        let blocked = model.translateBlocker != nil
        let isOn = model.translateLocked && !blocked
        let pressed = picker.isPressed || picker.phase == .tracking
        ZStack {
            Circle().fill(background(isOn: isOn, pressed: pressed))
            if isOn {
                Text(model.translateLanguage.shortLabel)
                    .font(.system(size: model.translateLanguage.shortLabel.count > 1 ? 15 : 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
                    .foregroundStyle(Color(.systemBackground))
            } else {
                Image(systemName: "translate")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(blocked ? 0.3 : 1))
            }
        }
        .frame(width: GlyphKey.side, height: GlyphKey.side)
        .contentShape(Circle())
        .background(
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(KeyboardSpace.name))
                Color.clear
                    .onAppear { picker.keyFrame = frame }
                    .onChange(of: frame) { _, newFrame in picker.keyFrame = newFrame }
            }
        )
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(KeyboardSpace.name))
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in picker.touchChanged(to: value.location) }
                .onEnded { value in picker.touchEnded(at: value.location) }
        )
        .onChange(of: touching) { _, isTouching in
            if !isTouching { picker.touchStateReset() }
        }
        .onDisappear { picker.keyDisappeared() }
        .accessibilityElement()
        .accessibilityLabel("翻譯")
        .accessibilityValue(accessibilityValue(isOn: isOn, blocked: blocked))
        .accessibilityHint(blocked ? "目前無法使用，點兩下查看原因" : "點兩下開關翻譯，也可以用動作選擇語言")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.translateKeyTapped() }
        .accessibilityActions {
            ForEach(model.translateQuickLanguages) { language in
                let title = "翻譯成\(language.displayName)"
                Button(title) { model.chooseTranslateLanguage(language, via: "voiceover") }
            }
        }
    }

    private func background(isOn: Bool, pressed: Bool) -> Color {
        if isOn { return pressed ? Color.primary.opacity(0.75) : Color.primary }
        return pressed ? KeyPalette.pressed(scheme) : KeyPalette.key(scheme)
    }

    private func accessibilityValue(isOn: Bool, blocked: Bool) -> String {
        if blocked { return "無法使用" }
        return isOn ? "開啟，\(model.translateLanguage.displayName)" : "關閉"
    }
}

// MARK: - The popup

/// Drawn over the whole keyboard (root overlay). Invisible and transparent to touches unless
/// the picker is open.
struct TranslatePopupOverlay: View {
    let model: KeyboardModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let picker = model.translatePicker
        ZStack(alignment: .topLeading) {
            if picker.phase == .sticky {
                // Like a menu: a tap anywhere else dismisses.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { picker.close(reason: "tapped-outside") }
                    .accessibilityHidden(true)
            }
            if picker.phase != .closed, let layout = picker.layout {
                panel(picker: picker, layout: layout)
                    .position(x: layout.panel.midX, y: layout.panel.midY)
                    .transition(.scale(scale: 0.82, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: picker.phase)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: picker.highlighted)
    }

    private func panel(picker: TranslatePicker, layout: TranslatePopupLayout) -> some View {
        let compact = layout.cellSize.height < 40
        return HStack(spacing: 0) {
            ForEach(Array(picker.options.enumerated()), id: \.element.id) { index, language in
                Button {
                    picker.tapOption(index)
                } label: {
                    cell(language, highlighted: picker.highlighted == index, compact: compact)
                        .frame(width: layout.cellSize.width, height: layout.cellSize.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("翻譯成\(language.displayName)")
            }
        }
        .padding(layout.padding)
        .frame(width: layout.panel.width, height: layout.panel.height)
        // Liquid Glass capsule on iOS 26+, system material before that — the same surface the
        // system uses for menus and controls, instead of a flat painted box.
        .liquidGlass(in: Capsule())
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.14), radius: 10, x: 0, y: 3)
        .allowsHitTesting(picker.phase == .sticky)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { picker.close(reason: "voiceover-escape") }
    }

    private func cell(_ language: TranslateLanguage, highlighted: Bool, compact: Bool) -> some View {
        let isCurrent = language.id == model.translateLanguage.id
        // One line, the language's name. The pill under the finger fills in; the language in
        // use right now is marked with a faint pill.
        return Text(language.displayName)
            .font(.system(size: compact ? 14 : 15, weight: highlighted || isCurrent ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .foregroundStyle(highlighted ? Color(.systemBackground) : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Capsule()
                    .fill(highlighted ? Color.primary : (isCurrent ? Color.primary.opacity(0.12) : Color.clear))
            )
            .scaleEffect(highlighted ? 1.04 : 1)
    }
}
