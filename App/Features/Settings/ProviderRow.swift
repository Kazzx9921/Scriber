import SwiftUI

/// One choice in an engine list, laid out like a Wi-Fi network row: a leading checkmark for the
/// selected one, name and a few words, and an independent control on the right.
/// The row and the trailing control are separate borderless buttons so each gets its own tap.
struct ProviderRow<Trailing: View>: View {
    let title: String
    let tag: String
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .foregroundStyle(Color.primary)
                        Text(tag)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            trailing
        }
    }
}

extension ProviderRow where Trailing == EmptyView {
    init(title: String, tag: String, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.init(title: title, tag: tag, isSelected: isSelected, onSelect: onSelect) { EmptyView() }
    }
}

/// Trailing control on a provider row: a tinted "設定 key" pill while the key is missing, a quiet
/// "已設定" afterwards. Both open the key editor.
struct KeyStatusButton: View {
    let isSet: Bool
    var setTitle: LocalizedStringKey = "設定 key"
    let action: () -> Void

    var body: some View {
        if isSet {
            Button(action: action) {
                Label("已設定", systemImage: "key.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("API key 已設定，點兩下管理")
        } else {
            Button(action: action) {
                Text(setTitle)
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.accentColor)
        }
    }
}
