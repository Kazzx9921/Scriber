import SwiftUI

/// Liquid Glass on macOS 26+, a material on macOS 14–25 (Mac copy of the iOS helper).
struct LiquidGlassBackground<S: Shape>: ViewModifier {
    var interactive: Bool
    var tint: Color?
    var shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), GlassSupport.isAvailable {
            content.glassEffect(glass, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    func liquidGlass(interactive: Bool = false, tint: Color? = nil, in shape: some Shape = Capsule()) -> some View {
        modifier(LiquidGlassBackground(interactive: interactive, tint: tint, shape: shape))
    }
}

/// Merges adjacent `.liquidGlass` children into one surface on macOS 26+; a pass-through before.
struct LiquidGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *), GlassSupport.isAvailable {
            GlassEffectContainer { content() }
        } else {
            content()
        }
    }
}
