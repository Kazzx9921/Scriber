import SwiftUI

/// The in-app mic, drawn like the keyboard's mic pill: a label-colored capsule (black on light,
/// white on dark) with the glyph in the background color. Tap to start, tap again to finish.
struct MicPill: View {
    enum Visual: Equatable { case idle, recording, processing }

    let visual: Visual
    let action: () -> Void

    static let size = CGSize(width: 172, height: 66)

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule().fill(Color.primary)
                content
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(visual == .processing)
        .animation(.easeOut(duration: 0.18), value: visual)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch visual {
        case .idle:
            Image(systemName: "mic.fill")
                .font(.system(size: Self.size.height * 0.4, weight: .semibold))
                .foregroundStyle(Color(.systemBackground))
                .transition(.opacity)
        case .recording:
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 9, height: 9)
                LevelBars(color: Color(.systemBackground))
                    .frame(height: Self.size.height * 0.5)
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        case .processing:
            ProgressView()
                .tint(Color(.systemBackground))
                .transition(.opacity)
        }
    }

    private var accessibilityLabel: String {
        switch visual {
        case .idle: String(localized: "開始說話")
        case .recording: String(localized: "完成")
        case .processing: String(localized: "整理中")
        }
    }
}

/// Round icon button that sits beside the pill (e.g. cancel while recording), like the keyboard's
/// glyph keys.
struct GlyphButton: View {
    let symbol: String
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .liquidGlass(interactive: true, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.9))
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Scrolling input-level bars, newest on the right. Only exists while recording; the timeline
/// stops as soon as the view is removed.
struct LevelBars: View {
    var color: Color
    @State private var trail = LevelTrail()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let samples = trail.advance(to: context.date)
            Canvas { gc, size in
                let barWidth: CGFloat = 3
                let gap: CGFloat = 3
                let count = min(samples.count, Int((size.width + gap) / (barWidth + gap)))
                guard count > 0 else { return }
                for (i, level) in samples.suffix(count).enumerated() {
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

/// Level history sampled from the engine at most ~30 times a second.
@MainActor
final class LevelTrail {
    static let capacity = 28
    private(set) var samples = [Float](repeating: 0, count: LevelTrail.capacity)
    private var lastSample = Date.distantPast

    func advance(to date: Date) -> [Float] {
        guard date.timeIntervalSince(lastSample) >= 1.0 / 30 else { return samples }
        lastSample = date
        // Read here, inside the bars' timeline, so only the bars redraw as the level changes.
        let level = DictationEngine.shared.level
        samples.removeFirst()
        samples.append(min(max(level, 0), 1))
        return samples
    }
}
