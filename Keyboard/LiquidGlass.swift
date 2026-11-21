import SwiftUI

// Copied from App/UI/LiquidGlass.swift (the two targets do not share sources), plus a tinted
// variant for the mic button's recording / translate / cancel states.

struct LiquidGlassBackground<S: Shape>: ViewModifier {
    var interactive: Bool
    var tint: Color?
    var shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let base: Glass = interactive ? .regular.interactive() : .regular
            content.glassEffect(tint.map { base.tint($0) } ?? base, in: shape)
        } else if let tint {
            content.background(tint, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    func liquidGlass(interactive: Bool = false, tint: Color? = nil, in shape: some Shape = Capsule()) -> some View {
        modifier(LiquidGlassBackground(interactive: interactive, tint: tint, shape: shape))
    }
}

/// A container that merges adjacent `.liquidGlass` children into one fluid glass surface on iOS 26+.
/// On older iOS it's a pass-through.
struct LiquidGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content() }
        } else {
            content()
        }
    }
}
