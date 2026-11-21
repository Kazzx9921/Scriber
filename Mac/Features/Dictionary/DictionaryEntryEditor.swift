import SwiftUI
import ScriberCore

/// Add or edit one dictionary entry: the correct spelling, big and first, then the usual
/// mis-hearings as removable chips. Typing a comma, 、 or Return turns the text into a chip;
/// Delete in the empty field removes the last chip.
struct DictionaryEntryEditor: View {
    let target: EditorTarget
    let store: DictionaryStore

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var soundsLike: [String]
    @State private var pending = ""
    @State private var confirmDelete = false
    @FocusState private var focus: Field?

    private enum Field { case term, soundsLike }

    /// Separators accepted while typing or pasting several mis-hearings at once.
    static let separators = CharacterSet(charactersIn: ",，、;；\n")

    init(target: EditorTarget, store: DictionaryStore) {
        self.target = target
        self.store = store
        switch target {
        case .new:
            _term = State(initialValue: "")
            _soundsLike = State(initialValue: [])
        case .edit(let entry):
            _term = State(initialValue: entry.term)
            _soundsLike = State(initialValue: entry.soundsLike)
        }
    }

    private var editingEntry: DictionaryEntry? {
        if case .edit(let entry) = target { return entry }
        return nil
    }

    private var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isDuplicate: Bool {
        store.entries.contains {
            $0.id != editingEntry?.id && $0.term.caseInsensitiveCompare(trimmedTerm) == .orderedSame
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(editingEntry == nil ? "新增詞彙" : "編輯詞彙").font(.headline)
            termField
            soundsLikeField
            HStack {
                if editingEntry != nil {
                    Button("刪除", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editingEntry == nil ? "新增" : "儲存", action: save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(trimmedTerm.isEmpty || isDuplicate)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { focus = editingEntry == nil ? .term : .soundsLike }
        .confirmationDialog("要刪除「\(trimmedTerm)」嗎？", isPresented: $confirmDelete) {
            Button("刪除", role: .destructive) {
                if let entry = editingEntry { store.remove(ids: [entry.id]) }
                dismiss()
            }
        }
    }

    // MARK: Fields

    private var termField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldCaption("正確寫法")
            TextField("例如：Claude Code", text: $term)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($focus, equals: .term)
                .onSubmit { focus = .soundsLike }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(fieldShape.fill(Color(nsColor: .textBackgroundColor)))
                .overlay(fieldShape.strokeBorder(isDuplicate ? Theme.accent : Color.primary.opacity(0.12),
                                                 lineWidth: isDuplicate ? 1.5 : 1))
            if isDuplicate {
                Label("字典裡已經有這個詞了", systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var soundsLikeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                FieldCaption("聽起來像")
                InfoButton("常被聽錯的寫法，例如「cloud code」。辨識結果出現這些字時，會自動換成上面的正確寫法。按 Return 或逗號加入一個。")
                Spacer()
                Text("選填").font(.caption).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 10) {
                if !soundsLike.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(soundsLike, id: \.self) { item in
                            SoundsLikeChip(text: item) { remove(item) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    TextField("加入聽錯的寫法", text: $pending)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .soundsLike)
                        .onSubmit { commitPending() }
                        .onChange(of: pending) { _, value in
                            // A separator typed or pasted turns everything before it into chips.
                            if value.rangeOfCharacter(from: Self.separators) != nil { commitPending(keepTail: true) }
                        }
                        .onKeyPress(.delete) {
                            guard pending.isEmpty, !soundsLike.isEmpty else { return .ignored }
                            soundsLike.removeLast()
                            return .handled
                        }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fieldShape.fill(Color(nsColor: .textBackgroundColor)))
            .overlay(fieldShape.strokeBorder(Color.primary.opacity(0.12)))
            .animation(.snappy(duration: 0.2), value: soundsLike)
        }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    // MARK: Editing

    /// Moves the typed text into chips. With `keepTail`, text after the last separator stays.
    private func commitPending(keepTail: Bool = false) {
        var parts = pending.components(separatedBy: Self.separators)
        let tail = keepTail ? (parts.popLast() ?? "") : ""
        for part in parts { add(part) }
        pending = tail
    }

    private func add(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.caseInsensitiveCompare(trimmedTerm) != .orderedSame,
              !soundsLike.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        soundsLike.append(value)
    }

    private func remove(_ item: String) {
        soundsLike.removeAll { $0 == item }
    }

    private func save() {
        guard !trimmedTerm.isEmpty, !isDuplicate else { return }
        // Text still in the field counts too.
        var all = soundsLike
        for part in pending.components(separatedBy: Self.separators) {
            let value = part.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, !all.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                all.append(value)
            }
        }
        let cleaned = all.filter { $0.caseInsensitiveCompare(trimmedTerm) != .orderedSame }
        if var entry = editingEntry {
            entry.term = trimmedTerm
            entry.soundsLike = cleaned
            store.update(entry)
        } else {
            store.add(DictionaryEntry(term: trimmedTerm, soundsLike: cleaned))
        }
        dismiss()
    }
}

private struct FieldCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// One mis-hearing: tinted capsule with a remove button.
private struct SoundsLikeChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(text)
                .font(.callout)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(IconButtonStyle())
            .help("移除")
            .accessibilityLabel("移除「\(text)」")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 1)
        .background(Capsule().fill(Theme.accent.opacity(0.16)))
    }
}
