import SwiftUI
import ScriberShared

/// `.sheet(item:)` wrapper so the contract enum doesn't need an `Identifiable` conformance.
struct APIKeySheetItem: Identifiable {
    let kind: APIKeyKind
    var id: String { kind.rawValue }
}

extension View {
    /// Presents the editor for a key: `APIKeyDetailView`, or the whole custom-engine form for
    /// `.custom` (its key is useless without a URL and model). Used by Home and Settings.
    func apiKeySheet(item: Binding<APIKeySheetItem?>) -> some View {
        sheet(item: item) { item in
            KeySheetContent(kind: item.kind)
        }
    }
}

private struct KeySheetContent: View {
    let kind: APIKeyKind
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if kind == .custom {
                CustomEngineView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { dismiss() }
                        }
                    }
            } else {
                APIKeyDetailView(kind: kind, focusOnAppear: true)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { dismiss() }
                        }
                    }
            }
        }
    }
}
