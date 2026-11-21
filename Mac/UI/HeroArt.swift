import SwiftUI

/// Scriber's own hero artwork, drawn in SwiftUI in the app icon's style: a terracotta disc, a white
/// studio microphone outlined in black ink and tilted as if drawn by hand, with an off-register ink
/// shadow, sound arcs and two scribbled "voice" lines. Everything sits on the disc, so it reads the
/// same in light and dark mode. Designed on a 200 × 200 grid and scaled to `size`.
struct MicDiscArt: View {
    var size: CGFloat = 200
    /// Draw the disc (off for placing the microphone on another terracotta surface).
    var showsDisc = true

    private static let ink = Theme.ink
    private static let stroke: CGFloat = 3.4

    var body: some View {
        ZStack {
            if showsDisc { disc }
            soundMarks
            microphone
                .rotationEffect(.degrees(-13), anchor: UnitPoint(x: 0.43, y: 0.55))
        }
        .frame(width: 200, height: 200)
        .scaleEffect(size / 200)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Disc

    private var disc: some View {
        Circle()
            .fill(
                LinearGradient(colors: [Theme.accent.opacity(0.92), Theme.accent, Color(red: 0.78, green: 0.40, blue: 0.27)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay(Circle().strokeBorder(Self.ink.opacity(0.14), lineWidth: 1.2))
            .frame(width: 192, height: 192)
    }

    // MARK: Sound

    private var soundMarks: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                // Kept inside the disc: the outer arc ends well before the rim.
                let radius = 46 + CGFloat(index) * 12
                Arc(center: CGPoint(x: 96, y: 70), radius: radius, from: -46 + Double(index) * 5, to: 14 - Double(index) * 3)
                    .stroke(Self.ink, style: StrokeStyle(lineWidth: 3.4 - CGFloat(index) * 0.5, lineCap: .round))
            }
            Scribble(start: CGPoint(x: 140, y: 118), width: 32, amplitude: 4.5, waves: 3)
                .stroke(Self.ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            Scribble(start: CGPoint(x: 137, y: 133), width: 26, amplitude: 3.8, waves: 2.5)
                .stroke(Self.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: Microphone

    private var microphone: some View {
        ZStack {
            // Off-register ink copy, like a hand-printed icon.
            micShapes(fill: Self.ink, outline: Self.ink)
                .offset(x: 3.2, y: 3.8)
            micShapes(fill: .white, outline: Self.ink)
        }
    }

    private func micShapes(fill: Color, outline: Color) -> some View {
        ZStack {
            // Holder (a white tube with ink edges) and stem.
            Holder()
                .stroke(outline, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
            Holder()
                .stroke(fill, style: StrokeStyle(lineWidth: 4.4, lineCap: .round, lineJoin: .round))
            Path { p in
                p.move(to: CGPoint(x: 86, y: 137))
                p.addLine(to: CGPoint(x: 86, y: 152))
            }
            .stroke(outline, style: StrokeStyle(lineWidth: 11, lineCap: .butt))
            Path { p in
                p.move(to: CGPoint(x: 86, y: 136))
                p.addLine(to: CGPoint(x: 86, y: 153))
            }
            .stroke(fill, style: StrokeStyle(lineWidth: 4.4, lineCap: .butt))

            // Base.
            Capsule()
                .fill(fill)
                .overlay(Capsule().strokeBorder(outline, lineWidth: Self.stroke))
                .frame(width: 54, height: 14)
                .position(x: 86, y: 156)

            // Knobs.
            ForEach([CGFloat(54), 118], id: \.self) { x in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(outline, lineWidth: 2.6))
                    .frame(width: 11, height: 16)
                    .position(x: x, y: 88)
            }

            // Head with its band.
            Capsule()
                .fill(fill)
                .overlay(Capsule().strokeBorder(outline, lineWidth: Self.stroke))
                .frame(width: 46, height: 78)
                .position(x: 86, y: 74)
            Path { p in
                p.move(to: CGPoint(x: 64, y: 84))
                p.addQuadCurve(to: CGPoint(x: 108, y: 84), control: CGPoint(x: 86, y: 88))
                p.move(to: CGPoint(x: 64, y: 93))
                p.addQuadCurve(to: CGPoint(x: 108, y: 93), control: CGPoint(x: 86, y: 97))
            }
            .stroke(outline, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            // A pen glint on the head.
            Path { p in
                p.move(to: CGPoint(x: 73, y: 52))
                p.addQuadCurve(to: CGPoint(x: 72, y: 74), control: CGPoint(x: 70, y: 62))
            }
            .stroke(outline.opacity(0.55), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
    }

    /// The U-shaped holder around the head.
    private struct Holder: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: 58, y: 86))
                p.addLine(to: CGPoint(x: 58, y: 106))
                p.addCurve(to: CGPoint(x: 114, y: 106), control1: CGPoint(x: 58, y: 142), control2: CGPoint(x: 114, y: 142))
                p.addLine(to: CGPoint(x: 114, y: 86))
            }
        }
    }

    /// An arc in degrees (0° = right, clockwise on screen).
    private struct Arc: Shape {
        let center: CGPoint
        let radius: CGFloat
        let from: Double
        let to: Double

        func path(in rect: CGRect) -> Path {
            Path { p in
                p.addArc(center: center, radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
            }
        }
    }

    /// A loose handwriting-like wave ("mm").
    private struct Scribble: Shape {
        let start: CGPoint
        let width: CGFloat
        let amplitude: CGFloat
        let waves: CGFloat

        func path(in rect: CGRect) -> Path {
            Path { p in
                let steps = 40
                for step in 0...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    // Slightly growing loops, like a quick pen stroke.
                    let y = start.y - sin(t * waves * 2 * .pi) * amplitude * (0.7 + 0.5 * t) - t * 3
                    let point = CGPoint(x: start.x + t * width, y: y)
                    if step == 0 { p.move(to: point) } else { p.addLine(to: point) }
                }
            }
        }
    }
}
