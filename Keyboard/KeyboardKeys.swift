import SwiftUI
import UIKit

/// System-keyboard-like key colors, light and dark.
enum KeyPalette {
    static func key(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 1, opacity: 0.30) : .white
    }
    static func functionKey(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 1, opacity: 0.15) : Color(red: 0.67, green: 0.69, blue: 0.73)
    }
    static func pressed(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 1, opacity: 0.45) : Color(red: 0.80, green: 0.82, blue: 0.85)
    }
    static func shadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.45) : .black.opacity(0.28)
    }
    static var cornerRadius: CGFloat {
        if #available(iOS 26.0, *) { return 9 } else { return 5 }
    }
}

/// Key cap with press feedback. `onPress` fires on touch-down, `onRelease` on lift
/// (or on cancellation), like the system keys.
struct KeyCap<Label: View>: View {
    var function = false
    var accessibility: String
    var onPress: () -> Void
    var onRelease: () -> Void = {}
    @ViewBuilder var label: () -> Label

    @Environment(\.colorScheme) private var scheme
    @GestureState private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KeyPalette.cornerRadius, style: .continuous)
        label()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.primary)
            .background(
                shape.fill(pressed ? KeyPalette.pressed(scheme)
                                   : (function ? KeyPalette.functionKey(scheme) : KeyPalette.key(scheme)))
                    .shadow(color: KeyPalette.shadow(scheme), radius: 0, x: 0, y: 1)
            )
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .onChange(of: pressed) { _, isDown in
                if isDown { onPress() } else { onRelease() }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibility)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onPress(); onRelease() }
    }
}

/// Round icon-only key. `onPress` fires on touch-down and `onRelease` on lift, like `KeyCap`.
struct GlyphKey: View {
    static let side: CGFloat = 42

    var symbol: String
    var accessibility: String
    var isOn = false
    var onPress: () -> Void
    var onRelease: () -> Void = {}

    @Environment(\.colorScheme) private var scheme
    @GestureState private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isOn ? Color(.systemBackground) : Color.primary)
            .frame(width: Self.side, height: Self.side)
            .background(
                Circle().fill(isOn ? Color.primary : (pressed ? KeyPalette.pressed(scheme) : KeyPalette.key(scheme)))
            )
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .onChange(of: pressed) { _, isDown in
                if isDown { onPress() } else { onRelease() }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibility)
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onPress(); onRelease() }
    }
}

/// The globe key must be a real UIControl so `handleInputModeList(from:with:)` can show the
/// long-press keyboard list, as Apple requires (tap = next keyboard, hold = list).
struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)
        button.setImage(UIImage(systemName: "globe", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "下一個鍵盤"
        if let controller {
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                             for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
