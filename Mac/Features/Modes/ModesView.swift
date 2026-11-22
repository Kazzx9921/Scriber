import SwiftUI
import ScriberCore
import ScriberShared

/// 模式 (docs/PRD-模式.md §6.1): one card per mode — icon, name, the 預設 marker, a row of small tags
/// (engine, language, AI, prompt) and its hotkey, with the on/off switch on the right. Click a card to
/// edit it (pushed inside the page, like a transcript in 轉錄); drag cards to reorder; the "…" that
/// appears on hover and the context menu hold 設為預設 / 複製 / 上移 / 下移 / 還原預設 or 刪除.
/// The header has 提示詞 (the prompt library) and 新增.
struct ModesView: View {
    let store: ModeStore
    let prompts: PromptLibrary
    /// Snapshots: open this mode's editor instead of the list.
    var initiallyOpen: String?
    /// Snapshots: open the prompt library.
    var showsLibrary = false

    @Environment(MacSettings.self) private var settings
    @Environment(EngineStatus.self) private var status
    @State private var openID: String?
    @State private var showLibrary = false
    @State private var deleting: DictationModeConfig?
    @State private var restoring: DictationModeConfig?
    @State private var dropTarget: String?
    @State private var didApplyInitial = false

    static let info = "模式是一組設定：用哪個辨識引擎、要不要 AI 整理、用哪個提示詞。主要快捷鍵用預設模式；模式也可以有自己的快捷鍵。「跟隨預設」用的是設定頁的值。"

    private var context: ModeContext {
        ModeContext(settings: settings, modes: store.modes, prompts: prompts.prompts,
                    accessibilityTrusted: status.accessibilityTrusted, hotkey: status.hotkey)
    }

    var body: some View {
        Group {
            if let id = openID, store.modes.contains(where: { $0.id == id }) {
                ModeEditorView(modeID: id, store: store, prompts: prompts) { openID = nil }
            } else {
                page
            }
        }
        .onAppear {
            store.reload()
            prompts.reload()
            guard !didApplyInitial else { return }
            didApplyInitial = true
            if let initiallyOpen { openID = initiallyOpen }
            if showsLibrary { showLibrary = true }
        }
        .sheet(isPresented: $showLibrary) {
            PromptLibraryView(library: prompts, modes: store)
        }
        .confirmationDialog("刪除「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil },
                                                                                set: { if !$0 { deleting = nil } })) {
            Button("刪除", role: .destructive) {
                if let mode = deleting { delete(mode) }
                deleting = nil
            }
        } message: {
            Text("這個動作無法復原。")
        }
        .confirmationDialog("把「\(restoring?.name ?? "")」還原成出廠設定？", isPresented: Binding(get: { restoring != nil },
                                                                                       set: { if !$0 { restoring = nil } })) {
            Button("還原") {
                if let mode = restoring { restore(mode) }
                restoring = nil
            }
        } message: {
            Text("名稱、圖示、快捷鍵和其他設定都會還原。")
        }
    }

    // MARK: Page

    private var page: some View {
        let context = context
        let routes = context.routes
        let current = context.currentModeID
        let enabledCount = store.modes.filter(\.isEnabled).count
        return VStack(spacing: 0) {
            PageHeader(title: "模式", subtitle: "\(store.modes.count) 個模式", info: Self.info) {
                HStack(spacing: 8) {
                    Button {
                        showLibrary = true
                    } label: {
                        Label("提示詞", systemImage: "text.quote")
                    }
                    .quietAction()
                    .help("AI 整理文字時用的指示")
                    Button {
                        add()
                    } label: {
                        Label("新增", systemImage: "plus")
                    }
                    .prominentAction()
                    .keyboardShortcut("n", modifiers: .command)
                    .help("新增模式（⌘N）")
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(store.modes.enumerated()), id: \.element.id) { index, mode in
                        card(mode, index: index, context: context, routes: routes, current: current,
                             canTurnOff: !(mode.isEnabled && enabledCount <= 1))
                    }
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 2)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func card(_ mode: DictationModeConfig, index: Int, context: ModeContext, routes: HotkeyRoutes,
                      current: String, canTurnOff: Bool) -> some View {
        let shortcut = mode.trigger.hotkey.flatMap(ModeShortcut.init)
        return ModeCard(
            mode: mode, isCurrent: mode.id == current, tags: context.tags(mode),
            keycaps: shortcut.map(context.keycaps), problem: context.problem(mode, routes: routes)?.message,
            canTurnOff: canTurnOff, isDropTarget: dropTarget == mode.id,
            onOpen: { openID = mode.id },
            onToggle: { setEnabled($0, mode) }
        ) {
            menuItems(mode, index: index, current: current)
        }
        .draggable(mode.id) {
            ModeIconBadge(symbol: mode.icon, size: 34)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first, store.modes.contains(where: { $0.id == id }) else { return false }
            move(id, before: mode.id)
            return true
        } isTargeted: { targeted in
            if targeted { dropTarget = mode.id } else if dropTarget == mode.id { dropTarget = nil }
        }
    }

    @ViewBuilder
    private func menuItems(_ mode: DictationModeConfig, index: Int, current: String) -> some View {
        Button("編輯…") { openID = mode.id }
        if mode.id != current {
            Button("設為預設") { settings.setCurrentMode(mode.id, store: store) }
        }
        Button("複製") { duplicate(mode) }
        Divider()
        Button("上移") { reorder(mode, by: -1) }
            .disabled(index == 0)
        Button("下移") { reorder(mode, by: 1) }
            .disabled(index == store.modes.count - 1)
        Divider()
        if mode.isBuiltIn {
            Button("還原預設…") { restoring = mode }
        } else {
            Button("刪除…", role: .destructive) { deleting = mode }
                .disabled(mode.isEnabled && store.modes.filter(\.isEnabled).count <= 1)
        }
    }

    // MARK: Actions

    private func add() {
        // Starts as plain dictation (everything follows the defaults); the editor opens right away.
        let made = store.add(DictationModeConfig(name: Self.newName(in: store.modes), icon: "star"))
        DiagLog.log("modes", "mode added id=\(made.id)")
        openID = made.id
    }

    static func newName(in modes: [DictationModeConfig]) -> String {
        let names = Set(modes.map(\.name))
        if !names.contains("新模式") { return "新模式" }
        var number = 2
        while names.contains("新模式 \(number)") { number += 1 }
        return "新模式 \(number)"
    }

    private func duplicate(_ mode: DictationModeConfig) {
        guard var copy = try? store.duplicate(id: mode.id) else { return }
        copy.name = String("\(mode.name) 副本".prefix(ModeEditorView.maxNameLength))
        // Two modes cannot share one hotkey: the copy starts without one.
        copy.trigger.hotkey = nil
        try? store.update(copy)
        DiagLog.log("modes", "mode duplicated from=\(mode.id) id=\(copy.id)")
    }

    private func delete(_ mode: DictationModeConfig) {
        do {
            try store.delete(id: mode.id)
            DiagLog.log("modes", "mode deleted id=\(mode.id)")
        } catch {
            DiagLog.log("modes", "mode delete refused id=\(mode.id) \(error)")
        }
    }

    private func restore(_ mode: DictationModeConfig) {
        try? store.restoreDefault(id: mode.id)
        DiagLog.log("modes", "mode restored id=\(mode.id)")
    }

    private func setEnabled(_ enabled: Bool, _ mode: DictationModeConfig) {
        do {
            try store.setEnabled(enabled, id: mode.id)
            if !enabled, mode.id == BuiltInModeID.translate.rawValue, settings.translateLocked {
                settings.translateLocked = false
            }
            DiagLog.log("modes", "mode enabled=\(enabled) id=\(mode.id)")
        } catch {
            DiagLog.log("modes", "mode enable refused id=\(mode.id) \(error)")
        }
    }

    private func reorder(_ mode: DictationModeConfig, by offset: Int) {
        var ids = store.modes.map(\.id)
        guard let index = ids.firstIndex(of: mode.id) else { return }
        let target = index + offset
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        store.reorder(ids: ids)
    }

    /// Drag and drop: the dragged mode goes where the card it was dropped on is.
    private func move(_ id: String, before targetID: String) {
        guard id != targetID else { return }
        var ids = store.modes.map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: targetID) else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        withAnimation(.snappy) { store.reorder(ids: ids) }
        dropTarget = nil
    }
}

/// One mode: icon, name (+ 預設), tags, hotkey, and on the right the "…" (on hover) and the switch.
struct ModeCard<Menu: View>: View {
    let mode: DictationModeConfig
    let isCurrent: Bool
    let tags: [ModeContext.Tag]
    let keycaps: [String]?
    let problem: String?
    let canTurnOff: Bool
    var isDropTarget = false
    let onOpen: () -> Void
    let onToggle: (Bool) -> Void
    @ViewBuilder var menu: Menu

    @State private var hovering = false
    @Environment(\.forcedHover) private var forcedHover

    private var highlighted: Bool { hovering || forcedHover }

    var body: some View {
        HStack(spacing: 12) {
            ModeIconBadge(symbol: mode.icon, enabled: mode.isEnabled, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(mode.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(mode.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    if isCurrent { DefaultModeBadge() }
                }
                HStack(spacing: 5) {
                    ForEach(tags, id: \.self) { ModeTagChip(tag: $0) }
                }
                .opacity(mode.isEnabled ? 1 : 0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let keycaps {
                hotkey(keycaps)
            }
            SwiftUI.Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .opacity(highlighted ? 1 : 0)
            .help("更多")
            .accessibilityLabel("「\(mode.name)」的更多動作")
            Toggle("啟用", isOn: Binding(get: { mode.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!canTurnOff)
                .help(canTurnOff ? (mode.isEnabled ? "停用" : "啟用") : "至少要有一個模式是開著的")
                .accessibilityLabel("啟用「\(mode.name)」")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(highlighted ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isDropTarget ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: isDropTarget ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: highlighted)
        .contextMenu { menu }
        .help("點一下編輯")
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "編輯", onOpen)
    }

    private func hotkey(_ keycaps: [String]) -> some View {
        HStack(spacing: 5) {
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .help(problem)
                    .accessibilityLabel(problem)
            }
            KeycapGroup(keycaps: keycaps)
                .opacity(mode.isEnabled && problem == nil ? 1 : 0.45)
        }
        .help(problem ?? "這個模式的快捷鍵")
    }
}
