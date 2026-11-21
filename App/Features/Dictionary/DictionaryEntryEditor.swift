import SwiftUI
import ScriberCore

/// Add or edit one dictionary entry: the correct spelling, big and first, then the usual
/// mis-hearings as removable chips.
struct DictionaryEntryEditor: View {
    let target: EditorTarget

    @Environment(DictionaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var term: String
    @State private var soundsLike: [String]
    @State private var pending = ""
    @State private var confirmDelete = false
    @FocusState private var focus: Field?

    private enum Field { case term, soundsLike }

    /// Separators accepted while typing or pasting several mis-hearings at once.
    private static let separators = CharacterSet(charactersIn: ",，、;；\n")

    init(target: EditorTarget) {
        self.target = target
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    termField
                    soundsLikeField
                    if editingEntry != nil {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            FullWidthLabel("刪除這個詞", systemImage: "trash")
                        }
                        .secondaryActionStyle()
                        .tint(.red)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(editingEntry == nil ? "新增詞彙" : "編輯詞彙")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingEntry == nil ? "新增" : "儲存", action: save)
                        .fontWeight(.semibold)
                        .disabled(trimmedTerm.isEmpty || isDuplicate)
                }
            }
            .confirmationDialog("要刪除「\(trimmedTerm)」嗎？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let entry = editingEntry { store.remove(ids: [entry.id]) }
                    Haptics.tap()
                    dismiss()
                }
            }
            .onAppear { if editingEntry == nil { focus = .term } }
        }
    }

    // MARK: Fields

    private var termField: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldCaption("正確寫法")
            TextField("例如：Claude Code", text: $term)
                .font(.title3.weight(.semibold))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .term)
                .submitLabel(.next)
                .onSubmit { focus = .soundsLike }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(fieldShape.fill(Color(.secondarySystemGroupedBackground)))
                .overlay {
                    fieldShape.strokeBorder(isDuplicate ? Color.orange : .clear, lineWidth: 1.5)
                }
            if isDuplicate {
                Label("字典裡已經有這個詞了", systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: isDuplicate)
    }

    private var soundsLikeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                FieldCaption("聽起來像")
                InfoButton("常被聽錯的寫法，例如「cloud code」。辨識結果出現這些字時，會自動換成上面的正確寫法。")
                    .font(.footnote)
                Spacer()
                Text("選填")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 12) {
                if !soundsLike.isEmpty {
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(soundsLike, id: \.self) { item in
                            SoundsLikeChip(text: item) { remove(item) }
                        }
                    }
                    .transition(.opacity)
                }
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                        .imageScale(.large)
                        .accessibilityHidden(true)
                    TextField("加入聽錯的寫法", text: $pending)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focus, equals: .soundsLike)
                        .submitLabel(.return)
                        .onSubmit { commitPending() }
                        .onChange(of: pending) { _, value in
                            // A separator typed or pasted turns everything before it into chips.
                            if value.rangeOfCharacter(from: Self.separators) != nil { commitPending(keepTail: true) }
                        }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fieldShape.fill(Color(.secondarySystemGroupedBackground)))
            .animation(.snappy, value: soundsLike)
        }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    // MARK: Editing

    /// Moves the typed text into chips. With `keepTail`, text after the last separator stays in the field.
    private func commitPending(keepTail: Bool = false) {
        var parts = pending.components(separatedBy: Self.separators)
        let tail = keepTail ? (parts.popLast() ?? "") : ""
        for part in parts { add(part) }
        pending = tail
        if !keepTail { focus = .soundsLike }
    }

    private func add(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.caseInsensitiveCompare(trimmedTerm) != .orderedSame,
              !soundsLike.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        soundsLike.append(value)
        Haptics.tap()
    }

    private func remove(_ item: String) {
        soundsLike.removeAll { $0 == item }
        Haptics.tap()
    }

    private func save() {
        // Text still in the field counts too, without the per-chip haptic or refocusing.
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
        Haptics.success()
        dismiss()
    }
}

private struct FieldCaption: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// One mis-hearing: tinted capsule with a remove button.
private struct SoundsLikeChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.subheadline)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("移除「\(text)」")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
    }
}
