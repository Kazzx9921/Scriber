import SwiftUI

/// A curated set of SF Symbols for a mode's icon (the Mac's set), in a grid. Choosing one goes back.
struct ModeIconPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    /// Everyday writing situations first, then tools and things. iOS 17-safe names only (the
    /// keyboard draws them too).
    static let symbols = [
        "mic", "sparkles", "translate", "pencil.and.scribble", "envelope", "bubble.left.and.text.bubble.right",
        "text.bubble", "message", "quote.bubble", "list.bullet", "checklist", "doc.text",
        "note.text", "book", "person.2", "briefcase", "graduationcap", "calendar",
        "chevron.left.forwardslash.chevron.right", "terminal", "keyboard", "globe", "lightbulb", "wand.and.stars",
        "star", "heart", "flag", "bolt", "paperplane", "phone",
        "cart", "hammer", "music.note", "camera", "leaf", "moon",
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button {
                        selection = symbol
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 19, weight: .medium))
                            // The chosen one inverted, like the keyboard's "on" keys (monochrome).
                            .foregroundStyle(symbol == selection ? Color(.systemBackground) : Color.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(symbol == selection ? Color.primary : Color(.secondarySystemGroupedBackground))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.92))
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(symbol == selection ? .isSelected : [])
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("圖示")
        .navigationBarTitleDisplayMode(.inline)
    }
}
