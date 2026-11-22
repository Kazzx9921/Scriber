import SwiftUI
import ScriberCore
import ScriberShared

/// 設定 → 模式 (docs/PRD-模式.md §6.2): the modes in the user's order. Tap one to edit it; 編輯 to
/// reorder or delete the user's own; + to add one. The keyboard's mode key long press lists the
/// first four modes it can use, so the order here is the order there.
struct ModesView: View {
    @Environment(ModeStore.self) private var store
    @Environment(PromptLibrary.self) private var library
    @Environment(SettingsModel.self) private var settings

    @State private var opened: OpenedMode?
    @State private var deleting: DictationModeConfig?

    private struct OpenedMode: Identifiable, Hashable { let id: String }

    private var info: ModeInfo { ModeInfo(settings: settings, modes: store.modes, prompts: library.prompts) }
    private var enabledCount: Int { store.modes.filter(\.isEnabled).count }

    var body: some View {
        let info = info
        List {
            Section {
                ForEach(store.modes) { mode in
                    NavigationLink {
                        ModeEditorView(modeID: mode.id)
                    } label: {
                        ModeRow(mode: mode, summary: info.summary(mode), isDefault: mode.id == info.defaultModeID)
                    }
                    .contextMenu { menu(for: mode, info: info) }
                    .swipeActions(edge: .trailing) {
                        if !mode.isBuiltIn {
                            Button("刪除", role: .destructive) { deleting = mode }
                        }
                        if mode.isEnabled {
                            if enabledCount > 1 {
                                Button("停用") { setEnabled(false, mode) }
                                    .tint(.gray)
                            }
                        } else {
                            Button("啟用") { setEnabled(true, mode) }
                                .tint(.gray)
                        }
                    }
                    .deleteDisabled(mode.isBuiltIn || (mode.isEnabled && enabledCount <= 1))
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                    DiagLog.log("modes", "modes reordered count=\(store.modes.count)")
                }
                .onDelete { offsets in
                    deleting = offsets.first.map { store.modes[$0] }
                }
            } header: {
                SectionTitle("模式") { Self.help }
            }

            Section {
                NavigationLink {
                    PromptLibraryView()
                } label: {
                    LabeledContent("提示詞", value: String(localized: "\(library.prompts.count) 個"))
                }
            }
        }
        .navigationTitle("模式")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: add) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增模式")
            }
        }
        .navigationDestination(item: $opened) { opened in
            ModeEditorView(modeID: opened.id)
        }
        .confirmationDialog("刪除「\(deleting?.name ?? "")」？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                if let mode = deleting { delete(mode) }
                deleting = nil
            }
        } message: {
            Text("這個動作無法復原。")
        }
        .onAppear {
            store.reload()
            library.reload()
        }
    }

    /// Behind the "?" of 模式.
    @ViewBuilder
    static var help: some View {
        InfoText("模式決定用哪個引擎、要不要 AI、用什麼提示詞。沒有改的設定跟著「設定」頁的預設值。")
        InfoItem(title: String(localized: "鍵盤的模式鍵"),
                 text: String(localized: "點一下在最近用的兩個模式間切換，長按選模式或翻譯的語言。長按時列出這裡前 4 個可以用的模式，拖曳排順序。"))
        InfoItem(title: String(localized: "改寫"), text: String(localized: "鍵盤上有選取文字時，麥克風會自動用「改寫」，所以它不在模式鍵裡。"))
        InfoItem(title: String(localized: "預設"), text: String(localized: "鍵盤沒有切換過時用這個模式，App 裡的麥克風也用它。"))
    }

    @ViewBuilder
    private func menu(for mode: DictationModeConfig, info: ModeInfo) -> some View {
        if mode.id != info.defaultModeID {
            Button {
                setDefault(mode)
            } label: {
                Label("設為預設", systemImage: "checkmark.circle")
            }
        }
        Button {
            duplicate(mode)
        } label: {
            Label("複製", systemImage: "plus.square.on.square")
        }
        if mode.isEnabled {
            Button {
                setEnabled(false, mode)
            } label: {
                Label("停用", systemImage: "pause.circle")
            }
            .disabled(enabledCount <= 1)
        } else {
            Button {
                setEnabled(true, mode)
            } label: {
                Label("啟用", systemImage: "play.circle")
            }
        }
        if mode.isBuiltIn {
            Button {
                try? store.restoreDefault(id: mode.id)
                DiagLog.log("modes", "mode restored id=\(mode.id)")
            } label: {
                Label("還原預設", systemImage: "arrow.uturn.backward")
            }
        } else {
            Button(role: .destructive) {
                deleting = mode
            } label: {
                Label("刪除", systemImage: "trash")
            }
            .disabled(mode.isEnabled && enabledCount <= 1)
        }
    }

    // MARK: Actions

    private func add() {
        let made = store.add(DictationModeConfig(name: ModeInfo.newName(in: store.modes), icon: "star"))
        DiagLog.log("modes", "mode added id=\(made.id)")
        Haptics.tap()
        opened = OpenedMode(id: made.id)
    }

    private func duplicate(_ mode: DictationModeConfig) {
        guard var copy = try? store.duplicate(id: mode.id) else { return }
        copy.name = String("\(mode.name) 副本".prefix(ModeInfo.maxNameLength))
        copy.trigger.hotkey = nil
        try? store.update(copy)
        DiagLog.log("modes", "mode duplicated from=\(mode.id) id=\(copy.id)")
    }

    private func setEnabled(_ enabled: Bool, _ mode: DictationModeConfig) {
        do {
            try store.setEnabled(enabled, id: mode.id)
            DiagLog.log("modes", "mode \(enabled ? "enabled" : "disabled") id=\(mode.id)")
        } catch {
            DiagLog.log("modes", "mode enable refused id=\(mode.id) \(error)")
        }
    }

    private func setDefault(_ mode: DictationModeConfig) {
        ModeActions.setDefault(mode.id, store: store)
    }

    private func delete(_ mode: DictationModeConfig) {
        do {
            try store.delete(id: mode.id)
            DiagLog.log("modes", "mode deleted id=\(mode.id)")
        } catch {
            DiagLog.log("modes", "mode delete refused id=\(mode.id) \(error)")
        }
    }
}

/// Things both the list and the editor do.
@MainActor
enum ModeActions {
    /// Makes the mode the default and switches the keyboard to it (the keyboard's current mode is
    /// the most recently used one).
    static func setDefault(_ id: String, store: ModeStore) {
        do {
            try store.setDefault(id: id)
            store.noteUsed(id: id)
            DiagLog.log("modes", "mode default id=\(id)")
            Haptics.tap()
        } catch {
            DiagLog.log("modes", "mode default refused id=\(id) \(error)")
        }
    }
}

/// Icon, name (+ 預設) and one line about what the mode does.
private struct ModeRow: View {
    let mode: DictationModeConfig
    let summary: (text: String, problem: String?)
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 12) {
            ModeIcon(symbol: mode.icon, enabled: mode.isEnabled)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.name)
                        .foregroundStyle(mode.isEnabled ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    if isDefault { DefaultModeBadge() }
                }
                if let problem = summary.problem {
                    HStack(spacing: 3) {
                        Image(systemName: "key.fill").imageScale(.small)
                        Text(problem)
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                } else if !summary.text.isEmpty {
                    Text(summary.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
