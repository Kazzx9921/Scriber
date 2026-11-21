import SwiftUI

/// Small spot illustration in the spirit of the app icon: a white glyph outlined in black ink on a
/// terracotta tile, tilted a little as if drawn by hand, with optional ink marks next to it
/// (e.g. the sound waves beside the icon's microphone).
///
/// Everything sits on the tile, so it reads the same in light and dark mode.
struct SpotIllustration: View {
    let symbol: String
    /// Optional ink mark drawn at the tile's upper right, e.g. "wave.3.right".
    var accent: String?
    var size: CGFloat = 96

    private static let ink = Color(red: 0.11, green: 0.09, blue: 0.08)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color.accentColor.gradient)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .strokeBorder(Self.ink.opacity(0.12), lineWidth: 1)
                }

            inkedGlyph
                .offset(x: accent == nil ? 0 : -size * 0.07, y: accent == nil ? 0 : size * 0.03)

            if let accent {
                Image(systemName: accent)
                    .font(.system(size: size * 0.2, weight: .heavy))
                    .foregroundStyle(Self.ink)
                    .rotationEffect(.degrees(-12))
                    .offset(x: size * 0.28, y: -size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(-4))
        .accessibilityHidden(true)
    }

    /// The glyph drawn eight times in ink around its position, then once in white on top: a cheap,
    /// symbol-agnostic outline that looks like a pen stroke. A slightly larger ink copy lower right
    /// gives the off-register, hand-printed feel of the icon.
    private var inkedGlyph: some View {
        let stroke = max(1.2, size * 0.02)
        let offsets: [CGSize] = [
            CGSize(width: -1, height: -1), CGSize(width: 0, height: -1), CGSize(width: 1, height: -1),
            CGSize(width: -1, height: 0), CGSize(width: 1, height: 0),
            CGSize(width: -1, height: 1), CGSize(width: 0, height: 1), CGSize(width: 1, height: 1),
        ]
        return ZStack {
            glyph.foregroundStyle(Self.ink)
                .offset(x: stroke * 1.6, y: stroke * 1.9)
            ForEach(offsets.indices, id: \.self) { index in
                glyph.foregroundStyle(Self.ink)
                    .offset(x: offsets[index].width * stroke, y: offsets[index].height * stroke)
            }
            glyph.foregroundStyle(.white)
        }
        .rotationEffect(.degrees(-9))
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
    }
}
