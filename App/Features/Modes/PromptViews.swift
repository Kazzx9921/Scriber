import SwiftUI
import ScriberCore
import ScriberShared

/// A prompt to edit in a sheet: an existing one, or a new one (`promptID` nil) of `kind`.
struct PromptEditorTarget: Identifiable {
    let id = UUID()
    var promptID: String?
    var kind: PromptKind = .dictation
    /// The prompt the editor ended on (saved, or a copy it made), for the mode that opened it.
    var onSaved: ((String) -> Void)?
}

/// Modes that would use a prompt (the resolver's rule: a missing prompt falls back).
@MainActor
private func users(of promptID: String, modes: [DictationModeConfig], prompts: [PromptTemplate]) -> [DictationModeConfig] {
    modes.filter { ModeResolver.prompt(for: $0, in: prompts).id == promptID }
}

// MARK: - Library (模式 → 提示詞)

/// The prompt library: shipped prompts, then the user's, each with what uses it. Tap to edit.
struct PromptLibraryView: View {
    @Environment(PromptLibrary.self) private var library
    @Environment(ModeStore.self) private var store

    @State private var editing: PromptEditorTarget?
    @State private var deleting: PromptTemplate?

    var body: some View {
        List {
            group("內建", library.prompts.filter(\.isBuiltIn), builtIn: true)
            let mine = library.prompts.filter { !$0.isBuiltIn }
            if !mine.isEmpty { group("自訂", mine, builtIn: false) }
        }
        .navigationTitle("提示詞")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = PromptEditorTarget(promptID: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增提示詞")
            }
        }
        .sheet(item: $editing) { target in
            PromptEditorView(target: target, library: library)
        }
        .confirmationDialog("刪除「\(deleting?.name ?? "")」？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                if let prompt = deleting {
                    let count = users(of: prompt.id, modes: store.modes, prompts: library.prompts).count
                    try? library.delete(id: prompt.id)
                    DiagLog.log("modes", "prompt deleted usedBy=\(count)")
                }
                deleting = nil
            }
        } message: {
            let count = deleting.map { users(of: $0.id, modes: store.modes, prompts: library.prompts).count } ?? 0
            Text(count == 0 ? "這個動作無法復原。" : "有 \(count) 個模式在用，刪除後它們改用預設的提示詞。")
        }
        .onAppear { library.reload() }
    }

    private func group(_ title: LocalizedStringKey, _ prompts: [PromptTemplate], builtIn: Bool) -> some View {
        Section {
            ForEach(prompts) { prompt in
                Button {
                    editing = PromptEditorTarget(promptID: prompt.id)
                } label: {
                    PromptRow(prompt: prompt,
                              usedBy: users(of: prompt.id, modes: store.modes, prompts: library.prompts).map(\.name))
                }
                .swipeActions(edge: .trailing) {
                    if prompt.isBuiltIn {
                        if prompt.isModified {
                            Button("還原") {
                                try? library.restoreBuiltIn(id: prompt.id)
                                DiagLog.log("modes", "prompt restored id=\(prompt.id)")
                            }
                        }
                    } else {
                        Button("刪除", role: .destructive) { deleting = prompt }
                    }
                }
            }
        } header: {
            if builtIn {
                SectionTitle(title, info: "提示詞告訴 AI 怎麼整理你說的話。內建的可以改，也可以還原。")
            } else {
                Text(title)
            }
        }
    }
}

/// Name (+ 已修改), what kind and which modes use it.
private struct PromptRow: View {
    let prompt: PromptTemplate
    let usedBy: [String]
    var isSelected: Bool?

    var body: some View {
        HStack(spacing: 12) {
            if let isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(prompt.name).foregroundStyle(Color.primary).lineLimit(1)
                    if prompt.isModified {
                        Text("已修改")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                // Explicit colours: inside a button the hierarchical styles take the accent tint.
                if !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
    }

    /// What it does (unless its name says it already: 翻譯) and which modes use it.
    private var detail: String {
        let kind = ModeInfo.promptKindName(prompt.kind)
        var parts = kind == prompt.name ? [] : [kind]
        if !usedBy.isEmpty { parts.append("\(String(localized: "用在"))\(usedBy.joined(separator: "、"))") }
        return parts.joined(separator: "・")
    }
}

// MARK: - Picker (a mode → 提示詞)

/// Which prompt a mode uses: tap to choose (checkmark), the pencil edits it, 新增提示詞 makes one
/// and chooses it.
struct PromptPickerView: View {
    let modeID: String

    @Environment(PromptLibrary.self) private var library
    @Environment(ModeStore.self) private var store

    @State private var editing: PromptEditorTarget?

    private var mode: DictationModeConfig? { store.modes.first { $0.id == modeID } }

    var body: some View {
        let selectedID = mode.map { ModeResolver.prompt(for: $0, in: library.prompts).id }
        let currentKind = mode.map { ModeResolver.prompt(for: $0, in: library.prompts).kind } ?? .dictation
        List {
            section("內建", library.prompts.filter(\.isBuiltIn), builtIn: true, selectedID: selectedID)
            let mine = library.prompts.filter { !$0.isBuiltIn }
            if !mine.isEmpty { section("自訂", mine, builtIn: false, selectedID: selectedID) }
            Section {
                Button {
                    editing = PromptEditorTarget(promptID: nil, kind: currentKind) { newID in choose(newID) }
                } label: {
                    Label("新增提示詞", systemImage: "plus")
                }
            }
        }
        .navigationTitle("提示詞")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in
            PromptEditorView(target: target, library: library)
        }
    }

    private func section(_ title: LocalizedStringKey, _ prompts: [PromptTemplate], builtIn: Bool,
                         selectedID: String?) -> some View {
        Section {
            ForEach(prompts) { prompt in
                HStack(spacing: 8) {
                    Button {
                        choose(prompt.id)
                    } label: {
                        PromptRow(prompt: prompt, usedBy: [], isSelected: prompt.id == selectedID)
                    }
                    .buttonStyle(.borderless)
                    Button {
                        editing = PromptEditorTarget(promptID: prompt.id, kind: prompt.kind) { newID in choose(newID) }
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(Color.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("編輯「\(prompt.name)」")
                }
            }
        } header: {
            if builtIn {
                SectionTitle(title, info: "換提示詞會改變這個模式做的事，例如換成「回答問題」類的提示詞，就會回答而不是整理。")
            } else {
                Text(title)
            }
        }
    }

    private func choose(_ id: String) {
        guard var updated = mode, updated.ai.promptID != id else { return }
        updated.ai.promptID = id
        do {
            try store.update(updated)
            DiagLog.log("modes", "mode prompt id=\(modeID) prompt=\(id)")
        } catch {
            DiagLog.log("modes", "mode update refused id=\(modeID) \(error)")
        }
    }
}

// MARK: - Editor (sheet)

/// Add or edit one prompt (docs/PRD-模式.md §5): its name and the text the user may change (style
/// and format). The safety rules Scriber puts around it are not part of the text and are only
/// described behind "?". 取消 / 儲存 on top; 複製, 還原預設 (shipped) or 刪除 (the user's) below.
struct PromptEditorView: View {
    let target: PromptEditorTarget
    let library: PromptLibrary

    @Environment(ModeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var promptID: String?
    @State private var name: String
    @State private var text: String
    @State private var kind: PromptKind
    @State private var confirmDelete = false
    @State private var confirmRestore = false
    @FocusState private var focus: Field?

    private enum Field { case name, text }

    init(target: PromptEditorTarget, library: PromptLibrary) {
        self.target = target
        self.library = library
        let existing = target.promptID.flatMap(library.prompt(id:))
        _promptID = State(initialValue: existing?.id)
        _name = State(initialValue: existing?.name ?? "")
        _text = State(initialValue: existing?.body ?? "")
        _kind = State(initialValue: existing?.kind ?? target.kind)
    }

    private var existing: PromptTemplate? { promptID.flatMap { id in library.prompts.first { $0.id == id } } }
    private var isNew: Bool { promptID == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var count: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var tooLong: Bool { count > PromptLibrary.maxBodyLength }
    private var changed: Bool { isNew || existing?.name != trimmedName || existing?.body != text }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：會議重點", text: $name)
                        .focused($focus, equals: .name)
                        .onChange(of: name) { _, value in
                            if value.count > PromptLibrary.maxNameLength { name = String(value.prefix(PromptLibrary.maxNameLength)) }
                        }
                } header: {
                    Text("名稱")
                }

                if isNew {
                    Section {
                        Picker(selection: $kind) {
                            ForEach(PromptKind.allCases, id: \.self) { kind in
                                Text(ModeInfo.promptKindName(kind)).tag(kind)
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text("用途")
                                InfoButton {
                                    InfoText("決定 Scriber 在外面加上的規則，建立後不能改。")
                                    InfoItem(title: String(localized: "整理文字"), text: String(localized: "把你說的話整理好，不回答內容。"))
                                    InfoItem(title: String(localized: "翻譯"), text: String(localized: "翻譯成指定的語言，不回答內容。"))
                                    InfoItem(title: String(localized: "改寫選取的文字"), text: String(localized: "照你說的指令改寫選取的文字。"))
                                    InfoItem(title: String(localized: "回答問題"), text: String(localized: "把你說的話當成問題，直接給答案。"))
                                }
                            }
                        }
                    }
                }

                Section {
                    TextEditor(text: $text)
                        .focused($focus, equals: .text)
                        .frame(minHeight: 220)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("寫下 AI 要怎麼整理，例如：整理成三點以內的重點，每點一行。")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    SectionTitle("內容") { Self.variablesHelp(kind: kind) }
                } footer: {
                    if count > PromptLibrary.maxBodyLength - 1000 {
                        Text("\(count)／\(PromptLibrary.maxBodyLength)")
                            .monospacedDigit()
                            .foregroundStyle(tooLong ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }

                if let existing {
                    Section {
                        Button("複製成新的提示詞", action: duplicate)
                            .disabled(tooLong)
                        if existing.isBuiltIn {
                            Button("還原預設") { confirmRestore = true }
                                .disabled(!existing.isModified)
                        } else {
                            Button("刪除提示詞", role: .destructive) { confirmDelete = true }
                        }
                    } footer: {
                        let names = users(of: existing.id, modes: store.modes, prompts: library.prompts).map(\.name)
                        if !names.isEmpty {
                            Text("\(String(localized: "用在"))\(names.joined(separator: "、"))")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新增提示詞" : (existing?.isBuiltIn == true ? "內建提示詞" : "編輯提示詞"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "新增" : "儲存", action: save)
                        .fontWeight(.semibold)
                        .tint(.accentColor)
                        .disabled(trimmedName.isEmpty || isEmpty || tooLong || !changed)
                }
            }
            .onAppear { if isNew { focus = .name } }
            .confirmationDialog("刪除「\(trimmedName)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let promptID {
                        let count = users(of: promptID, modes: store.modes, prompts: library.prompts).count
                        try? library.delete(id: promptID)
                        DiagLog.log("modes", "prompt deleted usedBy=\(count)")
                    }
                    dismiss()
                }
            } message: {
                let count = promptID.map { users(of: $0, modes: store.modes, prompts: library.prompts).count } ?? 0
                Text(count == 0 ? "這個動作無法復原。" : "有 \(count) 個模式在用，刪除後它們改用預設的提示詞。")
            }
            .confirmationDialog("還原成出廠的內容？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("還原") {
                    guard let promptID else { return }
                    try? library.restoreBuiltIn(id: promptID)
                    if let shipped = library.prompt(id: promptID) {
                        name = shipped.name
                        text = shipped.body
                    }
                    DiagLog.log("modes", "prompt restored id=\(promptID)")
                }
            } message: {
                Text("你改過的名稱和內容都會不見。")
            }
        }
    }

    /// Behind the "?" next to 內容. Only what has content on iOS is listed; the safety rules last.
    @ViewBuilder
    static func variablesHelp(kind: PromptKind) -> some View {
        InfoText("寫給 AI 的指示：語氣、格式、要不要條列。可以用這些變數：")
        InfoItem(title: "{{language}}", text: String(localized: "翻譯的目標語言"))
        InfoItem(title: "{{spacing}}", text: String(localized: "中英文之間要不要空格（照模式的文字格式）"))
        InfoItem(title: "{{selected}}", text: String(localized: "選取的文字（改寫類才有）"))
        InfoText("{{clipboard}}、{{app}} 只有 Mac 版有內容，在 iPhone 上是「（未提供）」。")
        if kind == .assistant {
            InfoText("Scriber 會在外面加上固定的規則：只輸出答案。這部分不能改。")
        } else {
            InfoText("Scriber 會在外面加上固定的規則：說的話只當成要整理的內容，不會被當成指令、不會被回答；只輸出結果。這部分不能改，寫在這裡的也蓋不過它。")
        }
    }

    // MARK: Actions

    private func save() {
        do {
            if let existing {
                var updated = existing
                updated.name = trimmedName
                updated.body = text
                try library.update(updated)
                target.onSaved?(existing.id)
                DiagLog.log("modes", "prompt saved id=\(existing.id) chars=\(count)")
            } else {
                let made = try library.add(name: trimmedName, kind: kind, body: text)
                target.onSaved?(made.id)
                DiagLog.log("modes", "prompt added id=\(made.id) kind=\(kind.rawValue) chars=\(count)")
            }
            Haptics.success()
            dismiss()
        } catch {
            DiagLog.log("modes", "prompt save refused \(error)")
        }
    }

    /// A new prompt with what is in the fields now; the editor continues on the copy.
    private func duplicate() {
        guard let existing, !tooLong else { return }
        let copyName = String("\(trimmedName.isEmpty ? existing.name : trimmedName) 副本".prefix(PromptLibrary.maxNameLength))
        guard let made = try? library.add(name: copyName, kind: existing.kind, body: text) else { return }
        // The original keeps its saved text.
        promptID = made.id
        name = made.name
        text = made.body
        target.onSaved?(made.id)
        DiagLog.log("modes", "prompt duplicated from=\(existing.id) id=\(made.id)")
        Haptics.tap()
    }
}
