import SwiftUI
import ScriberCore

/// Suggested starter entries offered in the dictionary tab.
enum DictionarySuggestions {
    static var entries: [DictionaryEntry] { DictionaryStore.builtInEntries }
}

struct DictionaryView: View {
    @Environment(DictionaryStore.self) private var store

    @State private var search = ""
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
        return DictionarySuggestions.entries.filter { !existing.contains($0.term.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("個人字典")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = .new
                    } label: {
                        Label("新增詞彙", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { target in
                DictionaryEntryEditor(target: target)
            }
            .sheet(isPresented: $showSuggestions) {
                SuggestedEntriesView(suggestions: pendingSuggestions)
            }
            .task {
                guard DebugLaunch.screen == "dictionaryEditor", let first = store.entries.first else { return }
                try? await Task.sleep(for: .milliseconds(500))
                editing = .edit(first)
            }
        }
    }

    private var list: some View {
        List {
            if search.isEmpty, !pendingSuggestions.isEmpty {
                Section {
                    Button {
                        showSuggestions = true
                    } label: {
                        Label("加入建議詞彙（\(pendingSuggestions.count)）", systemImage: "text.badge.plus")
                    }
                }
            }

            Section {
                ForEach(filtered) { entry in
                    Button {
                        editing = .edit(entry)
                    } label: {
                        DictionaryRow(entry: entry)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { filtered[$0].id })
                    withAnimation { store.remove(ids: ids) }
                    Haptics.tap()
                }
            } header: {
                if search.isEmpty {
                    SectionTitle("\(store.entries.count) 個詞彙", info: "辨識時會照這裡的寫法輸出。「聽起來像」的字出現時，會自動換成正確寫法。往左滑可以刪除。")
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋詞彙")
        .overlay {
            if filtered.isEmpty, !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(symbol: "character.book.closed.fill", title: "還沒有詞彙",
                       message: "人名、品牌、專有名詞，照你的寫法輸出。") {
            Button {
                editing = .new
            } label: {
                FullWidthLabel("新增詞彙", systemImage: "plus")
            }
            .primaryActionStyle()

            if !pendingSuggestions.isEmpty {
                Button {
                    showSuggestions = true
                } label: {
                    FullWidthLabel("加入建議詞彙")
                }
                .secondaryActionStyle()
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.term)
                .font(.body.weight(.medium))
            if !entry.soundsLike.isEmpty {
                Text(entry.soundsLike.joined(separator: "、"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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

// MARK: - Suggestions

private struct SuggestedEntriesView: View {
    let suggestions: [DictionaryEntry]

    @Environment(DictionaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var added: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(suggestions) { entry in
                        HStack {
                            DictionaryRow(entry: entry)
                            Button {
                                add(entry)
                            } label: {
                                Image(systemName: added.contains(entry.id) ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.title3)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.borderless)
                            .disabled(added.contains(entry.id))
                            .accessibilityLabel(added.contains(entry.id) ? "已加入" : "加入")
                        }
                    }
                } header: {
                    SectionTitle("常見詞彙", info: "常見的科技詞和中英夾雜用語。加入後可以再自己修改。")
                }
            }
            .navigationTitle("建議詞彙")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("全部加入") {
                        suggestions.filter { !added.contains($0.id) }.forEach(add)
                        dismiss()
                    }
                    .disabled(added.count == suggestions.count)
                }
            }
        }
    }

    private func add(_ entry: DictionaryEntry) {
        // Fresh id so built-ins and user copies never collide.
        store.add(DictionaryEntry(term: entry.term, soundsLike: entry.soundsLike))
        added.insert(entry.id)
        Haptics.tap()
    }
}
