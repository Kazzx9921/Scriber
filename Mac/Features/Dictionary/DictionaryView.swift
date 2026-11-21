import SwiftUI
import ScriberCore
import ScriberShared

/// 字典: list with search, add (⌘N) / edit (double-click, Return, hover pencil) / delete (⌫,
/// context menu), and the built-in suggestions. An illustrated empty state before the first entry.
struct DictionaryView: View {
    let store: DictionaryStore

    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var editing: EditorTarget?
    @State private var showSuggestions = false

    private var filtered: [DictionaryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            entry.term.localizedCaseInsensitiveContains(query)
                || entry.soundsLike.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var pendingSuggestions: [DictionaryEntry] {
        let existing = Set(store.entries.map { $0.term.lowercased() })
        return DictionaryStore.builtInEntries.filter { !existing.contains($0.term.lowercased()) }
    }

    static let info = "辨識結果出現「聽起來像」的寫法時，會自動換成正確寫法。人名、品牌、專有名詞都適合放這裡。"

    var body: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty {
                PageHeader(title: "字典", info: Self.info)
                EmptyStateView(symbol: "character.book.closed.fill", title: "還沒有詞彙",
                               message: "人名、品牌、專有名詞，照你的寫法輸出。") {
                    Button {
                        editing = .new
                    } label: {
                        Label("新增詞彙", systemImage: "plus")
                    }
                    .prominentAction()
                    .keyboardShortcut("n", modifiers: .command)
                    if !pendingSuggestions.isEmpty {
                        Button("加入建議詞彙") { showSuggestions = true }
                            .quietAction()
                    }
                }
            } else {
                PageHeader(title: "字典", subtitle: "\(store.entries.count) 個詞彙", info: Self.info) {
                    HStack(spacing: 8) {
                        SearchField(text: $search, width: 190)
                        if !pendingSuggestions.isEmpty {
                            Button {
                                showSuggestions = true
                            } label: {
                                Label("建議詞彙", systemImage: "sparkles")
                            }
                            .quietAction()
                            .help("加入常見的科技詞和中英夾雜詞")
                        }
                        Button {
                            editing = .new
                        } label: {
                            Label("新增", systemImage: "plus")
                        }
                        .prominentAction()
                        .keyboardShortcut("n", modifiers: .command)
                        .help("新增詞彙（⌘N）")
                    }
                }
                list
            }
        }
        .onAppear { store.reload() }
        .sheet(item: $editing) { target in
            DictionaryEntryEditor(target: target, store: store)
        }
        .sheet(isPresented: $showSuggestions) {
            SuggestionsSheet(store: store)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filtered) { entry in
                DictionaryRow(entry: entry) { editing = .edit(entry) }
                    .tag(entry.id)
                    .contextMenu {
                        Button("編輯…") { editing = .edit(entry) }
                        Button("刪除", role: .destructive) { store.remove(ids: [entry.id]) }
                    }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .contextMenu(forSelectionType: UUID.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let entry = store.entries.first(where: { $0.id == id }) { editing = .edit(entry) }
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            store.remove(ids: selection)
            selection.removeAll()
        }
        .overlay {
            if filtered.isEmpty, !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }
}

enum EditorTarget: Identifiable {
    case new
    case edit(DictionaryEntry)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let entry): entry.id.uuidString
        }
    }
}

/// The correct spelling, then what it is heard as (chips), and a pencil on hover.
private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    @State private var hovering = false

    private static let visibleChips = 4

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.term)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            if !entry.soundsLike.isEmpty {
                Image(systemName: "arrow.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("聽起來像")
                HStack(spacing: 5) {
                    ForEach(entry.soundsLike.prefix(Self.visibleChips), id: \.self) { item in
                        Text(item)
                            .font(.callout)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    if entry.soundsLike.count > Self.visibleChips {
                        Text("+\(entry.soundsLike.count - Self.visibleChips)")
                            .font(.callout)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("編輯")
            .accessibilityLabel("編輯「\(entry.term)」")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Built-in suggestions not added yet.
private struct SuggestionsSheet: View {
    let store: DictionaryStore
    @Environment(\.dismiss) private var dismiss

    private var remaining: [DictionaryEntry] {
        let existing = Set(store.entries.map { $0.term.lowercased() })
        return DictionaryStore.builtInEntries.filter { !existing.contains($0.term.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("建議詞彙").font(.title3.weight(.bold))
                    Text("常見的科技詞和中英夾雜詞").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("全部加入") {
                    for entry in remaining { store.add(DictionaryEntry(term: entry.term, soundsLike: entry.soundsLike)) }
                }
                .quietAction()
                .disabled(remaining.isEmpty)
            }
            .padding(20)
            Divider()
            if remaining.isEmpty {
                Label("都加入了", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(remaining) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.term).fontWeight(.medium)
                            if !entry.soundsLike.isEmpty {
                                Text(entry.soundsLike.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("加入") { store.add(DictionaryEntry(term: entry.term, soundsLike: entry.soundsLike)) }
                            .quietAction()
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(16)
        }
        .frame(width: 480, height: 480)
    }
}
