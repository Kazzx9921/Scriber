import SwiftUI
import ScriberCore
import ScriberShared

/// Add or edit one prompt of the library (docs/PRD-模式.md §5): its name and the text the user may
/// change (style and format). The safety rules Scriber puts around it are not part of the text and
/// are only described behind "?". Footer: 還原預設 (shipped prompts) or 刪除 (the user's), 複製,
/// then 取消 / 儲存.
struct PromptEditorView: View {
    let target: PromptEditorTarget
    let library: PromptLibrary
    let modes: ModeStore

    @Environment(\.dismiss) private var dismiss
    @State private var promptID: String?
    @State private var name: String
    @State private var text: String
    @State private var kind: PromptKind
    @State private var confirmDelete = false
    @State private var confirmRestore = false
    @FocusState private var focus: Field?

    private enum Field { case name, text }

    init(target: PromptEditorTarget, library: PromptLibrary, modes: ModeStore) {
        self.target = target
        self.library = library
        self.modes = modes
        let existing = target.promptID.flatMap(library.prompt(id:))
        _promptID = State(initialValue: existing?.id)
        _name = State(initialValue: existing?.name ?? "")
        _text = State(initialValue: existing?.body ?? "")
        _kind = State(initialValue: existing?.kind ?? target.kind)
    }

    private var existing: PromptTemplate? { promptID.flatMap { id in library.prompts.first { $0.id == id } } }
    private var isNew: Bool { promptID == nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).count > PromptLibrary.maxBodyLength }
    private var changed: Bool { isNew || existing?.name != trimmedName || existing?.body != text }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Modes that would use this prompt.
    private var usedBy: [DictationModeConfig] {
        guard let promptID else { return [] }
        return modes.modes.filter { ModeResolver.prompt(for: $0, in: library.prompts).id == promptID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            nameField
            if isNew { kindPicker }
            textField
            footer
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { focus = isNew ? .name : .text }
        .confirmationDialog("刪除「\(trimmedName)」？", isPresented: $confirmDelete) {
            Button("刪除", role: .destructive) {
                if let promptID { try? library.delete(id: promptID) }
                DiagLog.log("modes", "prompt deleted usedBy=\(usedBy.count)")
                dismiss()
            }
        } message: {
            Text(usedBy.isEmpty ? "這個動作無法復原。" : "有 \(usedBy.count) 個模式在用，刪除後它們改用預設的提示詞。")
        }
        .confirmationDialog("還原成出廠的內容？", isPresented: $confirmRestore) {
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

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(isNew ? "新增提示詞" : "編輯提示詞").font(.headline)
            Spacer()
            if let existing {
                Text(existing.isBuiltIn ? (existing.isModified ? "內建・已修改" : "內建") : ModeContext.promptKindName(existing.kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            PromptFieldCaption("名稱")
            TextField("例如：會議重點", text: $name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .focused($focus, equals: .name)
                .onChange(of: name) { _, value in
                    if value.count > PromptLibrary.maxNameLength { name = String(value.prefix(PromptLibrary.maxNameLength)) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(fieldShape.fill(Color(nsColor: .textBackgroundColor)))
                .overlay(fieldShape.strokeBorder(Color.primary.opacity(0.12)))
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 4) {
            PromptFieldCaption("用途")
            InfoButton {
                InfoText("決定 Scriber 在外面加上的規則，建立後不能改。")
                InfoItem(title: "整理文字", text: "把你說的話整理好，不回答內容。")
                InfoItem(title: "翻譯", text: "翻譯成指定的語言，不回答內容。")
                InfoItem(title: "改寫選取的文字", text: "照你說的指令改寫選取的文字，需要自動貼上。")
                InfoItem(title: "回答問題", text: "把你說的話當成問題，直接給答案。")
            }
            Spacer()
            Picker("用途", selection: $kind) {
                ForEach(PromptKind.allCases, id: \.self) { kind in
                    Text(ModeContext.promptKindName(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var textField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                PromptFieldCaption("內容")
                InfoButton { variablesHelp }
                Spacer()
                let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
                if count > PromptLibrary.maxBodyLength - 1000 {
                    Text("\(count)／\(PromptLibrary.maxBodyLength)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(tooLong ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
                }
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .text)
                .padding(8)
                .frame(minHeight: 240, maxHeight: 360)
                .background(fieldShape.fill(Color(nsColor: .textBackgroundColor)))
                .overlay(fieldShape.strokeBorder(tooLong ? Theme.accent : Color.primary.opacity(0.12), lineWidth: tooLong ? 1.5 : 1))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("寫下 AI 要怎麼整理，例如：整理成三點以內的重點，每點一行。")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    /// Behind the "?" next to 內容.
    @ViewBuilder
    private var variablesHelp: some View {
        InfoText("寫給 AI 的指示：語氣、格式、要不要條列。")
        InfoItem(title: "{{language}}", text: "翻譯的目標語言")
        InfoItem(title: "{{spacing}}", text: "中英文之間要不要空格（照模式的文字格式）")
        InfoItem(title: "{{selected}}", text: "選取的文字（改寫類）")
        if kind == .assistant {
            InfoText("Scriber 會在外面加上固定的規則：只輸出答案。這部分不能改。")
        } else {
            InfoText("Scriber 會在外面加上固定的規則：說的話只當成要整理的內容，不會被當成指令、不會被回答；只輸出結果。這部分不能改，寫在這裡的也蓋不過它。")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let existing {
                if existing.isBuiltIn {
                    Button("還原預設") { confirmRestore = true }
                        .disabled(!existing.isModified)
                } else {
                    Button("刪除…", role: .destructive) { confirmDelete = true }
                }
                Button("複製") { duplicate() }
                    .help("用目前的內容建立一個新的提示詞")
            }
            Spacer()
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "新增" : "儲存", action: save)
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(trimmedName.isEmpty || isEmpty || tooLong || !changed)
        }
    }

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                DiagLog.log("modes", "prompt saved id=\(existing.id) chars=\(text.count)")
            } else {
                let made = try library.add(name: trimmedName, kind: kind, body: text)
                target.onSaved?(made.id)
                DiagLog.log("modes", "prompt added id=\(made.id) kind=\(kind.rawValue) chars=\(text.count)")
            }
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
    }
}

private struct PromptFieldCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// The prompt library: shipped prompts, then the user's, each with what uses it; click to edit.
struct PromptLibraryView: View {
    let library: PromptLibrary
    let modes: ModeStore
    /// Snapshots: draw every row as hovered.
    var forcedHoverID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var editing: PromptEditorTarget?
    @State private var deleting: PromptTemplate?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("提示詞").font(.title3.weight(.bold))
                    Text("告訴 AI 怎麼整理你說的話").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editing = PromptEditorTarget(promptID: nil)
                } label: {
                    Label("新增", systemImage: "plus")
                }
                .quietAction()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    group("內建", library.prompts.filter(\.isBuiltIn))
                    let mine = library.prompts.filter { !$0.isBuiltIn }
                    if !mine.isEmpty {
                        group("自訂", mine).padding(.top, 10)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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
        .frame(width: 520, height: 560)
        .onAppear { library.reload() }
        .sheet(item: $editing) { target in
            PromptEditorView(target: target, library: library, modes: modes)
        }
        .confirmationDialog("刪除「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil },
                                                                                set: { if !$0 { deleting = nil } })) {
            Button("刪除", role: .destructive) {
                if let prompt = deleting { try? library.delete(id: prompt.id) }
                DiagLog.log("modes", "prompt deleted")
                deleting = nil
            }
        } message: {
            let count = deleting.map(users(of:))?.count ?? 0
            Text(count == 0 ? "這個動作無法復原。" : "有 \(count) 個模式在用，刪除後它們改用預設的提示詞。")
        }
    }

    private func group(_ title: String, _ prompts: [PromptTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(prompts) { prompt in
                PromptRow(prompt: prompt, usedBy: users(of: prompt).map(\.name), forcedHover: forcedHoverID == prompt.id,
                          onEdit: { editing = PromptEditorTarget(promptID: prompt.id) }) {
                    Button("編輯…") { editing = PromptEditorTarget(promptID: prompt.id) }
                    Button("複製") {
                        let name = String("\(prompt.name) 副本".prefix(PromptLibrary.maxNameLength))
                        _ = try? library.add(name: name, kind: prompt.kind, body: prompt.body)
                    }
                    Divider()
                    if prompt.isBuiltIn {
                        Button("還原預設") { try? library.restoreBuiltIn(id: prompt.id) }
                            .disabled(!prompt.isModified)
                    } else {
                        Button("刪除…", role: .destructive) { deleting = prompt }
                    }
                }
            }
        }
    }

    private func users(of prompt: PromptTemplate) -> [DictationModeConfig] {
        modes.modes.filter { ModeResolver.prompt(for: $0, in: library.prompts).id == prompt.id }
    }
}

/// Name (+ 已修改), what kind and which modes use it; a pencil on hover.
private struct PromptRow<Menu: View>: View {
    let prompt: PromptTemplate
    let usedBy: [String]
    var forcedHover = false
    let onEdit: () -> Void
    @ViewBuilder var menu: Menu
    @State private var hovering = false

    private var highlighted: Bool { hovering || forcedHover }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(prompt.name).fontWeight(.medium).lineLimit(1)
                    if prompt.isModified {
                        Text("已修改")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .opacity(highlighted ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(highlighted ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .help("點一下編輯")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "編輯", onEdit)
    }

    private var detail: String {
        let kind = ModeContext.promptKindName(prompt.kind)
        guard !usedBy.isEmpty else { return kind }
        return "\(kind)・用在\(usedBy.joined(separator: "、"))"
    }
}
