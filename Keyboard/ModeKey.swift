import SwiftUI
import UIKit
import ScriberCore
import ScriberShared

/// Coordinate space of the whole keyboard view, shared by the mode key's gesture and the popup
/// overlay so the popup is drawn exactly where the finger is hit-tested.
enum KeyboardSpace {
    static let name = "ScriberKeyboardSpace"
}

// MARK: - Popup options

/// One cell of the long-press popup: a mode (icon + name), or one quick language of the translate
/// mode (short label; the first one carries the translate mode's icon), one line each.
struct ModeKeyOption: Identifiable, Equatable {
    enum Kind: Equatable { case mode, language }

    var id: String
    var kind: Kind
    var modeID: String
    /// `.language`: the `TranslateLanguage` id it switches the translate mode to.
    var languageID: String?
    var symbol: String?
    var label: String
    /// A shorter label used when the row does not fit the keyboard ("EN" for 英文).
    var shortLabel: String?
    /// VoiceOver.
    var spoken: String
    /// What the mic uses now (a faint pill).
    var isCurrent: Bool
    /// Needs an AI key that is missing: dimmed; choosing it explains in the mic pill.
    var isBlocked: Bool

    /// The menu of `state`, the translate mode that follows the keyboard's language expanded into
    /// the quick languages.
    static func options(for state: KeyboardModes.State, quickLanguages: [TranslateLanguage],
                        currentLanguageID: String) -> [ModeKeyOption] {
        var options: [ModeKeyOption] = []
        for item in state.menu {
            let isCurrentMode = state.current?.id == item.id
            if item.id == state.languageItemID, !quickLanguages.isEmpty {
                for (index, language) in quickLanguages.enumerated() {
                    options.append(ModeKeyOption(
                        id: "language:\(language.id)", kind: .language, modeID: item.id, languageID: language.id,
                        symbol: index == 0 ? item.icon : nil, label: language.displayName,
                        shortLabel: language.shortLabel, spoken: "翻譯成\(language.displayName)",
                        isCurrent: isCurrentMode && currentLanguageID == language.id, isBlocked: item.isBlocked))
                }
            } else {
                var spoken = item.name
                if item.isTranslate, let id = item.translateLanguageID {
                    spoken += "，翻譯成\(TranslateLanguage.find(id).displayName)"
                }
                options.append(ModeKeyOption(id: "mode:\(item.id)", kind: .mode, modeID: item.id, languageID: nil,
                                             symbol: item.icon, label: item.name, shortLabel: nil, spoken: spoken,
                                             isCurrent: isCurrentMode, isBlocked: item.isBlocked))
            }
        }
        return options
    }

    // MARK: Sizes

    /// The options as drawn on a keyboard `width` wide: full language names when the row fits,
    /// their short labels (EN, 日, 韓) when it does not. Mode cells then shrink if still needed.
    static func fitted(_ options: [ModeKeyOption], width: CGFloat, compact: Bool) -> [ModeKeyOption] {
        let available = width - 2 * ModePopupLayout.margin - 2 * ModePopupLayout.padding(compact: compact)
        guard options.map({ $0.naturalWidth(compact: compact) }).reduce(0, +) > available else { return options }
        return options.map { option in
            var short = option
            if let label = option.shortLabel { short.label = label }
            return short
        }
    }

    static func labelFont(compact: Bool) -> UIFont {
        .systemFont(ofSize: 14, weight: .semibold)
    }

    static func symbolSize(compact: Bool) -> CGFloat { compact ? 13 : 14 }

    /// Room the cell needs for its icon and label on one line (padding 2 × 8 for a mode, 2 × 6 for
    /// a language, 5 between icon and label, a little slack).
    func naturalWidth(compact: Bool, withIcon: Bool = true) -> CGFloat {
        let text = ceil((label as NSString).size(withAttributes: [.font: Self.labelFont(compact: compact)]).width)
        let icon: CGFloat = withIcon ? symbol.map { Self.symbolWidth($0, compact: compact) + 5 } ?? 0 : 0
        switch kind {
        case .mode: return max(compact ? 50 : 54, text + icon + 20)
        case .language: return max(compact ? 34 : 38, text + icon + 16)
        }
    }

    /// Narrowest cell that still shows the icon and the whole label at its smallest scale (0.85).
    func minimumWidthWithIcon(compact: Bool) -> CGFloat {
        let text = ceil((label as NSString).size(withAttributes: [.font: Self.labelFont(compact: compact)]).width * 0.85)
        return text + (symbol.map { Self.symbolWidth($0, compact: compact) + 5 } ?? 0) + 16
    }

    /// The drawn width of an SF Symbol (they differ a lot: mic vs. translate).
    static func symbolWidth(_ name: String, compact: Bool) -> CGFloat {
        let configuration = UIImage.SymbolConfiguration(pointSize: symbolSize(compact: compact), weight: .semibold)
        return ceil(UIImage(systemName: name, withConfiguration: configuration)?.size.width ?? symbolSize(compact: compact) * 1.4)
    }
}

// MARK: - Popup geometry

/// Where the long-press popup sits, in `KeyboardSpace`. One value both draws the popup and
/// hit-tests the finger.
///
/// Placement: a single row of cells whose first cell sits over the mode key and the rest extend to
/// the right, over the mic pill; vertically just above the key, overlapping its top edge, and
/// pushed down when the keyboard is too short. Portrait (176 pt, key at y 43–85): panel y 3–51,
/// finger at y 64. Landscape (140 pt, key at y 29–71): panel y 3–41, finger at y 50. Always clamped
/// inside the keyboard bounds, which an extension cannot draw outside of. Mode cells shrink
/// (their names scale down) when the row would be wider than the keyboard.
struct ModePopupLayout: Equatable {
    var panel: CGRect
    var cells: [CGRect]
    var cellHeight: CGFloat
    var padding: CGFloat
    /// Area in which the finger selects a cell (by x only); outside it, releasing cancels.
    var zone: CGRect

    static let margin: CGFloat = 3

    static func padding(compact: Bool) -> CGFloat { compact ? 3 : 4 }

    /// `widths`: each cell's natural width; `shrinkable`: which ones may get narrower (mode cells).
    static func make(key: CGRect, bounds: CGSize, widths: [CGFloat], shrinkable: [Bool], compact: Bool) -> ModePopupLayout {
        let cellHeight: CGFloat = compact ? 32 : 40
        let padding = padding(compact: compact)
        let fitted = fit(widths, shrinkable: shrinkable, available: bounds.width - 2 * margin - 2 * padding)
        let width = fitted.reduce(0, +) + 2 * padding
        let height = cellHeight + 2 * padding
        let x = clamp(key.minX - padding, low: margin, high: bounds.width - margin - width)
        let y = clamp(key.minY + 6 - height, low: margin, high: bounds.height - margin - height)
        let panel = CGRect(x: x, y: y, width: width, height: height)
        var cells: [CGRect] = []
        var cursor = x + padding
        for cellWidth in fitted {
            cells.append(CGRect(x: cursor, y: y + padding, width: cellWidth, height: cellHeight))
            cursor += cellWidth
        }
        // Generous vertically (a finger sliding sideways along the key row still selects), a
        // little wider than the panel horizontally.
        let zoneTop = panel.minY - 40
        let zoneBottom = max(panel.maxY + 16, key.maxY + 10)
        let zone = CGRect(x: panel.minX - 16, y: zoneTop, width: panel.width + 32, height: zoneBottom - zoneTop)
        return ModePopupLayout(panel: panel, cells: cells, cellHeight: cellHeight, padding: padding, zone: zone)
    }

    /// The cell under the finger, nil outside the zone.
    func index(at point: CGPoint) -> Int? {
        guard !cells.isEmpty, zone.contains(point) else { return nil }
        // Cells are contiguous: the first one whose right edge is past the finger. The outer
        // cells extend to the zone's edges.
        return cells.firstIndex { point.x < $0.maxX } ?? cells.count - 1
    }

    /// Trims the widest shrinkable cells first (one common cap, not below 40 pt) until the row fits,
    /// so short names keep their full cell and only long ones are cut.
    static func fit(_ widths: [CGFloat], shrinkable: [Bool], available: CGFloat) -> [CGFloat] {
        guard widths.reduce(0, +) > available else { return widths }
        let fixed = zip(widths, shrinkable).filter { !$0.1 }.map(\.0).reduce(0, +)
        let flexible = zip(widths, shrinkable).filter(\.1).map(\.0).sorted()
        guard !flexible.isEmpty else { return widths }
        var remaining = available - fixed
        var cap = remaining / CGFloat(flexible.count)
        for (index, width) in flexible.enumerated() {
            cap = remaining / CGFloat(flexible.count - index)
            if width <= cap { remaining -= width } else { break }
        }
        cap = max(40, floor(cap))
        return zip(widths, shrinkable).map { width, canShrink in canShrink ? min(width, cap) : width }
    }

    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}

// MARK: - Gesture state machine

/// The mode key's touch handling, kept out of the view so the key and the popup overlay (drawn at
/// the root, above everything) share it.
///
/// - Tap (released before `holdDuration`, finger still near the key): `onTap` (switch between
///   the two most recent modes).
/// - Hold `holdDuration`: the popup opens with nothing highlighted.
///   - Drag: once the finger has moved `armDistance` from where the popup opened, the cell under
///     it is highlighted (a selection haptic per change). Release on a cell chooses it; release
///     outside the zone cancels.
///   - Release without moving: the popup stays open ("sticky") and its cells are tapped instead;
///     a tap anywhere else dismisses it.
@MainActor
@Observable
final class ModePicker {
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
    private(set) var options: [ModeKeyOption] = []
    private(set) var layout: ModePopupLayout?
    private(set) var isPressed = false

    /// Reported by the views; only read when the popup opens, so not observed.
    @ObservationIgnored var keyFrame: CGRect = .zero
    @ObservationIgnored var containerSize: CGSize = .zero

    // Wired by KeyboardModel.
    @ObservationIgnored var onTap: () -> Void = {}
    /// Options and orientation, or nil to refuse.
    @ObservationIgnored var openContext: () -> (options: [ModeKeyOption], compact: Bool)? = { nil }
    @ObservationIgnored var onChoose: (ModeKeyOption, String) -> Void = { _, _ in }
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
        if reason != "chosen" { KBLog.log("mode picker closed reason=\(reason)") }
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
        guard keyFrame != .zero, containerSize != .zero, let context = openContext(), !context.options.isEmpty else {
            current.spent = true // refused (e.g. no Full Access)
            touch = current
            isPressed = false
            return
        }
        options = ModeKeyOption.fitted(context.options, width: containerSize.width, compact: context.compact)
        layout = ModePopupLayout.make(key: keyFrame, bounds: containerSize,
                                      widths: options.map { $0.naturalWidth(compact: context.compact) },
                                      shrinkable: options.map { $0.kind == .mode }, compact: context.compact)
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
        let option = options[index]
        close(reason: "chosen")
        onChoose(option, via)
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

/// What the round key left of the mic shows.
enum ModeKeyLook: Equatable {
    /// The base mode (聽寫) is current: a plain key with the icon of what a tap switches to, like the
    /// old translate key switched off. Dimmed when that mode needs a missing AI key.
    case calm(symbol: String, dimmed: Bool)
    /// Another mode is current: the inverted "on" style with its icon…
    case active(symbol: String)
    /// …or, for a translate mode, its language's short label (EN, 日, 韓).
    case activeLabel(String)
}

/// Round key left of the mic: tap switches between the two most recent modes, long press lists
/// the modes and the translate languages.
struct ModeKey: View {
    let model: KeyboardModel

    @Environment(\.colorScheme) private var scheme
    @GestureState private var touching = false

    var body: some View {
        let picker = model.modePicker
        let look = model.modeKeyLook
        let pressed = picker.isPressed || picker.phase == .tracking
        ZStack {
            Circle().fill(background(look, pressed: pressed))
            switch look {
            case .calm(let symbol, let dimmed):
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(dimmed ? 0.3 : 1))
            case .active(let symbol):
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(.systemBackground))
            case .activeLabel(let label):
                Text(label)
                    .font(.system(size: label.count > 1 ? 15 : 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
                    .foregroundStyle(Color(.systemBackground))
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
        .accessibilityLabel("模式")
        .accessibilityValue(model.modeAccessibilityValue)
        .accessibilityHint(model.modeAccessibilityHint)
        .accessibilityAddTraits(isActive(look) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.modeKeyTapped() }
        .accessibilityActions {
            ForEach(model.modeOptions) { option in
                Button(option.spoken) { model.chooseModeOption(option, via: "voiceover") }
            }
        }
    }

    private func isActive(_ look: ModeKeyLook) -> Bool {
        if case .calm = look { return false }
        return true
    }

    private func background(_ look: ModeKeyLook, pressed: Bool) -> Color {
        if isActive(look) { return pressed ? Color.primary.opacity(0.75) : Color.primary }
        return pressed ? KeyPalette.pressed(scheme) : KeyPalette.key(scheme)
    }
}

// MARK: - The popup

/// Drawn over the whole keyboard (root overlay). Invisible and transparent to touches unless
/// the picker is open.
struct ModePopupOverlay: View {
    let model: KeyboardModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let picker = model.modePicker
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

    private func panel(picker: ModePicker, layout: ModePopupLayout) -> some View {
        let compact = layout.cellHeight < 40
        return HStack(spacing: 0) {
            ForEach(Array(picker.options.enumerated()), id: \.element.id) { index, option in
                Button {
                    picker.tapOption(index)
                } label: {
                    // A cell too short for its icon and whole name drops the icon: the name says
                    // more than the symbol.
                    cell(option, highlighted: picker.highlighted == index, compact: compact,
                         showsIcon: option.kind == .language
                            || layout.cells[index].width >= option.minimumWidthWithIcon(compact: compact))
                        .frame(width: layout.cells[index].width, height: layout.cellHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.spoken)
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

    private func cell(_ option: ModeKeyOption, highlighted: Bool, compact: Bool, showsIcon: Bool) -> some View {
        // One line: the icon and the name (a language: its short label). The pill under the
        // finger fills in; what the mic uses right now is marked with a faint pill.
        HStack(spacing: 5) {
            if showsIcon, let symbol = option.symbol {
                Image(systemName: symbol)
                    .font(.system(size: ModeKeyOption.symbolSize(compact: compact), weight: .semibold))
            }
            Text(option.label)
                .font(.system(size: 14, weight: highlighted || option.isCurrent ? .semibold : .medium))
                .lineLimit(1)
                // A long name on a narrow keyboard: a little smaller, then cut off (still legible).
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
        }
        .padding(.horizontal, option.kind == .mode ? 8 : 6)
        // Dimmed through the colour, not `.opacity`, which the glass surface does not show.
        .foregroundStyle(highlighted ? Color(.systemBackground) : Color.primary.opacity(option.isBlocked ? 0.3 : 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule()
                .fill(highlighted ? Color.primary : (option.isCurrent ? Color.primary.opacity(0.12) : Color.clear))
        )
        .scaleEffect(highlighted ? 1.04 : 1)
    }
}
