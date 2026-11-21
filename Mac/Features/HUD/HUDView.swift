import AppKit
import SwiftUI
import ScriberShared

/// What the floating pill shows.
enum HUDState: Equatable {
    case hidden
    /// `badge`: short language label in translate mode ("EN", "日").
    case recording(DictationMode, badge: String?)
    case processing(DictationMode)
    case feedback(HUDFeedback)
}

@MainActor
@Observable
final class HUDModel {
    var state: HUDState = .hidden
    /// Set while a clickable message (retry, open settings) is shown.
    @ObservationIgnored var onClick: (() -> Void)?
    @ObservationIgnored let levels = LevelHistory()
    /// Incremented for each problem message: the pill shakes once (like the iOS keyboard's).
    var shakes = 0

    // Real-time transcription (only while recording with a live session).
    /// This recording streams text: the pill grows into a panel once the first text arrives.
    var liveEnabled = false
    /// Recognized text, already Traditional (Taiwan). The committed part is stable between commits.
    var liveCommitted = ""
    /// The segment still being recognized, drawn dimmer at the end.
    var livePartial = ""

    /// Transient hint shown in the recording pill's top row in place of the waveform.
    var recordingHint: String?

    var hasLiveText: Bool { liveEnabled && !(liveCommitted.isEmpty && livePartial.isEmpty) }
}

/// The floating pill: same look and vocabulary as the iOS keyboard's mic pill. Monochrome capsule
/// in the label color (black on light, white on dark) — Liquid Glass tinted that colour on
/// macOS 26+ — with a red dot + live waveform while recording, a spinner while processing, and an
/// icon + a label of a few characters for messages (problems get the accent icon and one shake).
///
/// Real-time mode: while recording, the pill grows into a compact panel (same dot and waveform on
/// top, the last one or two lines of recognized text below, newest at the end, older text fading
/// out at the top). Size changes only once, when the first text arrives; text updates are not
/// animated, so changing partials never make the panel jump.
struct HUDView: View {
    let model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let pillHeight: CGFloat = 44
    /// Width of the live-text panel; `HUDController.livePanelSize` leaves room around it.
    static let liveWidth: CGFloat = 340

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            pill
                .modifier(ShakeEffect(shakes: reduceMotion ? 0 : CGFloat(model.shakes)))
                .animation(reduceMotion ? nil : .linear(duration: 0.4), value: model.shakes)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: model.state)
    }

    @ViewBuilder
    private var pill: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case let .recording(mode, badge):
            recording(mode, badge: badge, expanded: model.hasLiveText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mode == .dictate ? "聆聽中" : "\(mode.displayName)聆聽中")
        case let .processing(mode):
            capsule {
                HStack(spacing: 10) {
                    ArcSpinner(color: onPill)
                    if mode != .dictate {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(onPill.opacity(0.8))
                    }
                }
                .padding(.horizontal, 22)
            }
            .accessibilityLabel("整理中")
        case let .feedback(feedback):
            capsule {
                HStack(spacing: 7) {
                    Image(systemName: feedback.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(feedback.isProblem ? Theme.accent : onPill)
                    Text(feedback.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(onPill)
                    if feedback.kind == .needsSetup || feedback.kind == .retry {
                        Image(systemName: feedback.kind == .retry ? "hand.tap" : "arrow.up.forward")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(onPill.opacity(0.6))
                    }
                }
                .padding(.horizontal, 18)
            }
            .id(feedback)
            .contentShape(Capsule())
            .onTapGesture {
                // Only reachable while the panel accepts the mouse (a clickable message).
                guard let action = model.onClick else { return }
                model.onClick = nil
                action()
            }
            .accessibilityLabel(feedback.message)
        }
    }

    @ViewBuilder
    private func modeMark(_ mode: DictationMode, badge: String?) -> some View {
        switch mode {
        case .dictate:
            EmptyView()
        case .translate:
            Text(badge ?? "譯")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(onPill)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(Capsule().stroke(onPill.opacity(0.6), lineWidth: 1))
        case .edit:
            Image(systemName: mode.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(onPill)
        }
    }

    /// The recording pill, or the live-text panel it grows into. One view in both cases (a rounded
    /// rectangle with the pill's corner radius is the capsule), so the change is a smooth resize.
    private func recording(_ mode: DictationMode, badge: String?, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 9, height: 9)
                modeMark(mode, badge: badge)
                if expanded { Spacer(minLength: 0) }
                if let hint = model.recordingHint {
                    Text(hint)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(onPill)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 92, alignment: .trailing)
                        .transition(.opacity)
                } else {
                    WaveformView(history: model.levels, color: onPill)
                        .frame(width: 92, height: Self.pillHeight * 0.5)
                        .transition(.opacity)
                }
            }
            .frame(height: expanded ? 24 : Self.pillHeight)
            if expanded {
                LiveTextView(committed: model.liveCommitted, partial: model.livePartial, color: onPill)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, expanded ? 10 : 0)
        .padding(.bottom, expanded ? 12 : 0)
        .frame(width: expanded ? Self.liveWidth : nil)
        .frame(minWidth: 150)
        .frame(height: expanded ? nil : Self.pillHeight)
        .modifier(PillBackground(cornerRadius: Self.pillHeight / 2))
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9), value: expanded)
        .transition(appearance)
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(minWidth: 150)
            .frame(height: Self.pillHeight)
            .modifier(PillBackground())
            .transition(appearance)
    }

    /// Reduce Motion: fade only, no scaling.
    private var appearance: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
    }

    /// The pill is always a dark surface (see `PillBackground`), so its content is always white.
    /// It floats over arbitrary windows and wallpapers; following the app's light/dark appearance
    /// made the text unreadable on backgrounds of the "wrong" brightness.
    private var onPill: Color { .white }
}

/// A dark glass surface that stays readable over any background: Liquid Glass (macOS 26+) or a
/// system material (macOS 14–25) for the look, with a dark scrim on top of it that guarantees
/// contrast for the white content whatever is behind the panel — a bright page, a dark editor or
/// a colourful wallpaper.
/// `cornerRadius` nil: a capsule; otherwise a rounded rectangle (the live-text panel, which at the
/// pill's height and a radius of half of it is the same capsule).
private struct PillBackground: ViewModifier {
    var cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        Group {
            if let cornerRadius {
                background(content, shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                background(content, shape: Capsule())
            }
        }
        // Dark variant of the glass/material regardless of the system appearance.
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func background<S: InsettableShape>(_ content: Content, shape: S) -> some View {
        let scrim = shape.fill(Color.black.opacity(0.62))
        let edge = shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        if #available(macOS 26.0, *) {
            content
                .background(scrim)
                .glassEffect(.regular, in: shape)
                .overlay(edge)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        } else {
            content
                .background(scrim)
                .background(.ultraThinMaterial, in: shape)
                .overlay(edge)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
    }
}

/// The last two lines of the live text. Short text starts at the top; once it no longer fits, the
/// end stays on the bottom line, earlier lines move up out of view and the top line fades.
/// No animation on text changes: a partial that changes is simply redrawn in place.
struct LiveTextView: View {
    let committed: String
    let partial: String
    let color: Color
    @State private var overflowing = false

    static let fontSize: CGFloat = 14
    static let lineSpacing: CGFloat = 3
    static let lines = 2
    /// Two lines of 14 pt text plus line spacing, and a point of slack so nothing is cut at the top.
    static let areaHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font))
        return CGFloat(lines) * line + CGFloat(lines - 1) * lineSpacing + 2
    }()

    var body: some View {
        TailLayout {
            (Text(committed).foregroundColor(color.opacity(0.96)) + Text(partial).foregroundColor(color.opacity(0.62)))
                .font(.system(size: Self.fontSize, weight: .medium))
                .lineSpacing(Self.lineSpacing)
                .multilineTextAlignment(.leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: LiveTextHeightKey.self, value: geometry.size.height)
                })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.areaHeight)
        .clipped()
        .mask(fade)
        .onPreferenceChange(LiveTextHeightKey.self) { height in
            let over = height > Self.areaHeight + 0.5
            if over != overflowing { overflowing = over }
        }
        .accessibilityHidden(true)
    }

    /// Older text fades out toward the top, only when some of it is already out of view.
    private var fade: LinearGradient {
        overflowing
            ? LinearGradient(stops: [.init(color: .black.opacity(0.12), location: 0),
                                     .init(color: .black, location: 0.5)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [.black], startPoint: .top, endPoint: .bottom)
    }
}

private struct LiveTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Lays out its single child at its natural height for the available width: top-aligned while it
/// fits, bottom-aligned once it is taller (the overflow goes up, where the parent clips it). At the
/// exact fit both placements are the same, so the switch never moves anything.
private struct TailLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? HUDView.liveWidth
        let height = proposal.height ?? subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let y = size.height <= bounds.height ? bounds.minY : bounds.maxY - size.height
        child.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

/// Spinner that does not depend on the system's (gray) progress indicator, so it reads on both a
/// black and a white pill. Only exists while processing.
struct ArcSpinner: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
                .frame(width: 18, height: 18)
        }
        .accessibilityHidden(true)
    }
}

/// Recent levels for the waveform. Advances at most ~30 times a second however many views ask.
final class LevelHistory {
    static let capacity = 28
    /// Reads the recorder's current level.
    var provider: (() -> Float)?
    private(set) var samples = [Float](repeating: 0, count: LevelHistory.capacity)
    private var lastSample = Date.distantPast

    func reset() {
        samples = [Float](repeating: 0, count: Self.capacity)
        lastSample = .distantPast
    }

    func advance(to date: Date) -> [Float] {
        guard date.timeIntervalSince(lastSample) >= 1.0 / 30 else { return samples }
        lastSample = date
        let level = provider?() ?? 0
        samples.removeFirst()
        samples.append(level)
        return samples
    }
}

/// Scrolling level bars (port of the keyboard's `WaveformView`). TimelineView drives it at ≤30 fps
/// and stops as soon as the view is removed, so nothing ticks while idle.
struct WaveformView: View {
    let history: LevelHistory
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let samples = history.advance(to: context.date)
            Canvas { gc, size in
                let barWidth: CGFloat = 3
                let gap: CGFloat = 3
                let count = min(samples.count, Int((size.width + gap) / (barWidth + gap)))
                guard count > 0 else { return }
                let recent = samples.suffix(count)
                for (i, level) in recent.enumerated() {
                    let x = size.width - CGFloat(count - i) * (barWidth + gap) + gap
                    let h = max(3, CGFloat(level) * size.height)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    let fade = 0.35 + 0.65 * Double(i + 1) / Double(count)
                    gc.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(fade)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
