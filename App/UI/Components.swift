import SwiftUI
import UIKit

// MARK: - Buttons

extension View {
    /// Full-width primary action at the bottom of a page. Glass on iOS 26+, bordered prominent before.
    @ViewBuilder
    func primaryActionStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        } else {
            self.buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }

    /// Full-width secondary action under a primary one.
    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        } else {
            self.buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }

    /// Pins content to the bottom edge. Uses the iOS 26 scroll-edge bar when available.
    @ViewBuilder
    func bottomBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .bottom) { content() }
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) {
                content().background(.bar)
            }
        }
    }

    /// Rounded glass card (PhotoClean's status-card recipe). Before iOS 26 it falls back to the
    /// grouped-row color, which reads better than a thin material on a flat background.
    func card(padding: CGFloat = 18, cornerRadius: CGFloat = 22) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

private struct CardBackground: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.liquidGlass(in: shape)
        } else {
            content.background(Color(.secondarySystemGroupedBackground), in: shape)
        }
    }
}

/// Shrinks slightly while pressed. For custom-drawn buttons (mic pill, chips) that have no
/// system press state.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Label used inside primary/secondary buttons so they stretch to full width.
struct FullWidthLabel: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Info on demand

/// A small "?" that shows a short explanation in a popover, instead of a permanent footer.
/// Pass `label` to show a word next to the icon (e.g. "為什麼？") where an icon alone is too quiet.
struct InfoButton<Content: View>: View {
    var label: LocalizedStringKey?
    @ViewBuilder var content: Content

    @State private var isShown = false

    init(label: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        Button {
            isShown = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle")
                if let label { Text(label) }
            }
            .foregroundStyle(label == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label.map { Text($0) } ?? Text("說明"))
        .popover(isPresented: $isShown) {
            VStack(alignment: .leading, spacing: 8) { content }
                .font(.subheadline)
                .frame(width: 272, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }
}

extension InfoButton where Content == InfoText {
    init(_ text: LocalizedStringKey, label: LocalizedStringKey? = nil) {
        self.init(label: label) { InfoText(text) }
    }
}

/// Body text inside an `InfoButton` popover.
struct InfoText: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

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

/// List section header with an optional "?" right after the title.
struct SectionTitle<Info: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var info: Info

    init(_ title: LocalizedStringKey, @ViewBuilder info: () -> Info) {
        self.title = title
        self.info = info()
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            InfoButton { info }
                .font(.footnote)
        }
        .textCase(nil)
    }
}

extension SectionTitle where Info == InfoText {
    init(_ title: LocalizedStringKey, info: LocalizedStringKey) {
        self.init(title) { InfoText(info) }
    }
}

// MARK: - Empty states

/// Centered illustration, title, one short line and stacked actions. Scrolls when it does not fit
/// (large Dynamic Type).
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    var accent: String?
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    @ViewBuilder var actions: Actions

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView { content.padding(.vertical, 24) }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            SpotIllustration(symbol: symbol, accent: accent, size: 92)
                .padding(.bottom, 24)
            Text(title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            VStack(spacing: 10) { actions }
                .frame(maxWidth: 300)
                .padding(.top, 28)
        }
        .padding(.horizontal, 32)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, accent: String? = nil, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.init(symbol: symbol, accent: accent, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Copy

/// Copies text to the clipboard and briefly shows 已拷貝.
struct CopyButton: View {
    let text: String
    var title: LocalizedStringKey = "拷貝"

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            Haptics.success()
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            // Plain HStack rather than Label so list rows don't promote the icon to a row icon.
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "已拷貝" : title)
            }
        }
        .disabled(text.isEmpty)
    }
}

// MARK: - Status

/// "已設定" / "未設定" style trailing status.
struct StatusBadge: View {
    let isOn: Bool
    var onText: String = "已設定"
    var offText: String = "未設定"

    var body: some View {
        if isOn {
            Label(onText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Text(offText)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Numbered steps

struct NumberedStep: View {
    let number: Int
    let text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.tint))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            text
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Open Settings

enum SystemSettings {
    static var appSettingsURL: URL { URL(string: UIApplication.openSettingsURLString)! }
}
