import SwiftUI

/// Scrolling level bars. Only exists while recording; TimelineView drives it at ≤30 fps and
/// stops as soon as the view is removed, so nothing ticks when idle.
struct WaveformView: View {
    let history: LevelHistory
    /// Newest sample on the trailing edge (false) or the leading edge (true, the left half).
    var newestOnLeading = false
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
                    // i == count-1 is the newest sample.
                    let slot = newestOnLeading ? (count - 1 - i) : i
                    let x = newestOnLeading
                        ? CGFloat(slot) * (barWidth + gap)
                        : size.width - CGFloat(count - slot) * (barWidth + gap) + gap
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
