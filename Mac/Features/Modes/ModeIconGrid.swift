import SwiftUI

/// A curated set of SF Symbols for a mode's icon, in a small grid (popover from 圖示).
struct ModeIconGrid: View {
    @Binding var selection: String

    /// Everyday writing situations first, then tools and things.
    static let symbols = [
        "mic", "sparkles", "translate", "pencil.and.scribble", "envelope", "bubble.left.and.text.bubble.right",
        "text.bubble", "message", "quote.bubble", "list.bullet", "checklist", "doc.text",
        "note.text", "book", "person.2", "briefcase", "graduationcap", "calendar",
        "chevron.left.forwardslash.chevron.right", "terminal", "keyboard", "globe", "lightbulb", "wand.and.stars",
        "star", "heart", "flag", "bolt", "paperplane", "phone",
        "cart", "hammer", "music.note", "camera", "leaf", "moon",
    ]

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Self.symbols, id: \.self) { symbol in
                IconCell(symbol: symbol, isSelected: symbol == selection) { selection = symbol }
            }
        }
        .padding(12)
    }

    private struct IconCell: View {
        let symbol: String
        let isSelected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.primary))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Theme.accent.opacity(0.16) : Color.primary.opacity(hovering ? 0.07 : 0))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(symbol)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}
