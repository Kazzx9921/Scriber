import AppKit
import SwiftUI

enum Theme {
    /// Terracotta orange #D97757 (the app icon's colour). Also the asset catalog's AccentColor.
    static let accent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    /// Terracotta for text on plain or warm backgrounds: darker in light mode, lighter in dark
    /// mode, so big numbers keep their contrast.
    static let accentText = adaptive(light: NSColor(red: 0.70, green: 0.33, blue: 0.21, alpha: 1),
                                     dark: NSColor(red: 0.95, green: 0.63, blue: 0.50, alpha: 1))

    /// The icon's black ink.
    static let ink = Color(red: 0.11, green: 0.09, blue: 0.08)

    /// Warm paper behind the home hero.
    static let heroTop = adaptive(light: NSColor(red: 0.99, green: 0.95, blue: 0.92, alpha: 1),
                                  dark: NSColor(red: 0.21, green: 0.15, blue: 0.13, alpha: 1))
    static let heroBottom = adaptive(light: NSColor(red: 0.97, green: 0.86, blue: 0.80, alpha: 1),
                                     dark: NSColor(red: 0.16, green: 0.12, blue: 0.10, alpha: 1))

    /// Hairline used by cards and fields.
    static let hairline = Color.primary.opacity(0.08)

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Liquid Glass availability

/// Liquid Glass is used on macOS 26+. Off-screen snapshot renders cannot draw it, so they force
/// the fallback styles (which are drawn by SwiftUI and therefore visible in a capture).
@MainActor
enum GlassSupport {
    static var forceFallback = false

    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return !forceFallback }
        return false
    }
}

// MARK: - Buttons

extension View {
    /// The one main action of a screen: terracotta Liquid Glass on macOS 26+, a terracotta capsule
    /// before. Never stretched full width.
    func prominentAction() -> some View {
        modifier(ActionButtonModifier(prominent: true))
    }

    /// A quieter action next to (or instead of) the prominent one.
    func quietAction() -> some View {
        modifier(ActionButtonModifier(prominent: false))
    }

    /// Kept for older call sites: same as `prominentAction()` at large size.
    func primaryActionStyle() -> some View {
        prominentAction().controlSize(.large)
    }

    func secondaryActionStyle() -> some View {
        quietAction().controlSize(.large)
    }
}

private struct ActionButtonModifier: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), GlassSupport.isAvailable {
            if prominent {
                content.buttonStyle(.glassProminent).tint(Theme.accent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            content.buttonStyle(CapsuleButtonStyle(prominent: prominent))
        }
    }
}

/// Capsule button for macOS 14–25 (and snapshot renders): terracotta fill for the main action,
/// a soft tinted fill for the others, with hover and press feedback. Follows `controlSize`.
struct CapsuleButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct CapsuleButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var large: Bool { controlSize == .large || controlSize == .extraLarge }

        var body: some View {
            configuration.label
                .font(large ? .body.weight(.semibold) : .callout.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, large ? 18 : 11)
                .frame(minHeight: large ? 34 : 24)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(prominent ? Color.black.opacity(0.06) : Theme.hairline))
                .shadow(color: prominent && isEnabled ? Theme.accent.opacity(0.28) : .clear, radius: 6, y: 2)
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
        }

        private var fill: Color {
            if prominent {
                if configuration.isPressed { return Theme.accent.mix(with: .black, by: 0.12) }
                return hovering && isEnabled ? Theme.accent.mix(with: .white, by: 0.08) : Theme.accent
            }
            return Color.primary.opacity(configuration.isPressed ? 0.14 : hovering && isEnabled ? 0.10 : 0.065)
        }
    }
}

private extension Color {
    /// Linear blend in sRGB (macOS 14 has no `Color.mix`).
    func mix(with other: Color, by amount: CGFloat) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * amount }
        return Color(red: lerp(a.redComponent, b.redComponent), green: lerp(a.greenComponent, b.greenComponent),
                     blue: lerp(a.blueComponent, b.blueComponent))
    }
}

// MARK: - Surfaces

extension View {
    /// A quiet grouped surface: faint fill and hairline, the same in light and dark.
    func card(radius: CGFloat = 14) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Large page title at the top of a main-window page, with an optional line under it and
/// controls on the right.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 26, weight: .bold))
                    if let info {
                        InfoButton(info).font(.body)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 28)
        .padding(.top, MainLayout.topInset)
        .padding(.bottom, 14)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, info: String? = nil) {
        self.init(title: title, subtitle: subtitle, info: info) { EmptyView() }
    }
}

/// Rounded search field: magnifier, plain text field, clear button.
struct SearchField: View {
    @Binding var text: String
    var prompt = "搜尋"
    var width: CGFloat = 200
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除")
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 30)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: focused ? 1.5 : 1))
        .onExitCommand { text = "" }
    }
}

// MARK: - Status and live problems

/// A quiet status: a small dot and secondary text ("● 已開啟"). Green when on, grey when simply
/// off, terracotta when it blocks something.
struct StatusBadge: View {
    var isOn: Bool
    var onText = "已設定"
    var offText = "未設定"
    /// Off and in the way (e.g. microphone denied).
    var attention = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOn ? Color.green : attention ? Theme.accent : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(isOn ? onText : offText)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// A live problem the user has to act on (icon + a few words), with an optional action button.
/// Not for explanations: those go behind `InfoButton`.
struct ProblemRow: View {
    let symbol: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - "?" help

/// A small "?" that shows its explanation in a popover. Explanatory text never sits on screen
/// permanently; it lives here.
struct InfoButton<Content: View>: View {
    var label: String?
    @ViewBuilder var content: Content
    @State private var isShown = false
    @State private var hovering = false

    init(label: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "questionmark.circle")
                if let label { Text(label) }
            }
            .foregroundStyle(label == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accentText))
            .opacity(hovering ? 0.7 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label ?? "說明")
        .accessibilityLabel(label ?? "說明")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) { content }
                .font(.callout)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
    }
}

extension InfoButton where Content == InfoText {
    init(_ text: String, label: String? = nil) {
        self.init(label: label) { InfoText(text) }
    }
}

struct InfoText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One "name — one-liner" entry inside an `InfoButton` popover.
struct InfoItem: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Form section header with an optional "?" right after the title.
struct SectionHeader<Info: View>: View {
    let title: String
    @ViewBuilder var info: Info

    init(_ title: String, @ViewBuilder info: () -> Info) {
        self.title = title
        self.info = info()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton { info }
                .font(.callout)
        }
    }
}

extension SectionHeader where Info == InfoText {
    init(_ title: String, info: String) {
        self.init(title) { InfoText(info) }
    }
}

// MARK: - Empty states

/// Centered illustration, title, one short line and the actions side by side (natural width).
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    var accent: String?
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            SpotIllustration(symbol: symbol, accent: accent, size: 92)
                .padding(.bottom, 24)
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                    .padding(.top, 6)
            }
            HStack(spacing: 10) { actions }
                .controlSize(.large)
                .padding(.top, 22)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, accent: String? = nil, title: String, message: String? = nil) {
        self.init(symbol: symbol, accent: accent, title: title, message: message) { EmptyView() }
    }
}

/// Button label with an optional leading symbol (name kept from the first version; no longer
/// stretched full width).
struct FullWidthLabel: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

// MARK: - Hover and press feedback

/// Snapshot renders draw hover-only controls as if the pointer were over them.
private struct ForcedHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var forcedHover: Bool {
        get { self[ForcedHoverKey.self] }
        set { self[ForcedHoverKey.self] = newValue }
    }
}

/// Press feedback only (the row around it draws the hover highlight).
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A whole-row button: soft highlight on hover, a bit darker while pressed.
struct RowButtonStyle: ButtonStyle {
    var verticalPadding: CGFloat = 5
    var horizontalPadding: CGFloat = 6
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, verticalPadding: verticalPadding,
                      horizontalPadding: horizontalPadding, cornerRadius: cornerRadius)
    }

    private struct RowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let verticalPadding: CGFloat
        let horizontalPadding: CGFloat
        let cornerRadius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.10 : hovering ? 0.05 : 0))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Icon button: circle highlight on hover, slight shrink on press.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0)))
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

// MARK: - Keycaps

/// A key drawn like a keyboard key: "⌥", "Space", "右 ⌥".
struct Keycap: View {
    let text: String
    var large = false

    var body: some View {
        Text(text)
            .font(.system(large ? .body : .callout, design: .rounded).weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, large ? 10 : 7)
            .frame(minWidth: large ? 30 : 24, minHeight: large ? 28 : 22)
            .background(
                RoundedRectangle(cornerRadius: large ? 7 : 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.16), radius: 0, x: 0, y: 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: large ? 7 : 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            )
    }
}

/// Several keycaps side by side: [⌥][Space].
struct KeycapGroup: View {
    let keycaps: [String]
    var large = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, key in
                Keycap(text: key, large: large)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keycaps.joined(separator: " "))
    }
}

/// "按 [⌥][Space] 開始說話，再按一次結束" for the hotkey that works right now.
struct HotkeyHint: View {
    let active: ActiveHotkey
    let mode: TriggerMode
    var large = false

    var body: some View {
        switch active {
        case .unavailable(.comboTaken):
            Label("快捷鍵無法使用", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accentText)
        case .unavailable:
            Text("快捷鍵準備中…")
        default:
            HStack(spacing: 6) {
                Text(mode == .toggle ? "按" : "按住")
                KeycapGroup(keycaps: active.keycaps, large: large)
                Text(mode == .toggle ? "開始說話，再按一次結束" : "說話，放開結束")
            }
        }
    }
}

// MARK: - Layout

/// Lays children out left to right and wraps to a new line when the next one does not fit
/// (copy of the iOS `FlowLayout`).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = measure(subview, maxWidth: maxWidth)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: subviews.isEmpty ? 0 : y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = measure(subview, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func measure(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

/// One quick horizontal shake per increment of `shakes` (same as the iOS keyboard's pill).
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var travel: CGFloat = 5

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 4), y: 0))
    }
}
