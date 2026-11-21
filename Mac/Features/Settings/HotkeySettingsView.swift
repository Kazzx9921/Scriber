import AppKit
import SwiftUI
import ScriberShared

/// 快捷鍵 section rows, in the order people need them:
/// 1. 快捷鍵 — the hotkey in effect (single key with automatic paste, key combination without), as
///    keycaps with one 更改.
/// 2. 操作方式 — segmented: 點一下 / 按住說話.
/// 3. 說話改字 / 翻譯 — compact pop-ups for the modifier held with the hotkey.
/// 4. The other kind of hotkey (備用組合鍵, or 單鍵 before automatic paste) behind a disclosure.
/// Problems (combination taken, Fn setting, not yet active) show as a line under the row's title.
struct HotkeySettingsView: View {
    /// Snapshot renders: start with the other hotkey shown.
    var showsOther = false

    @Environment(MacSettings.self) private var settings
    @Environment(EngineStatus.self) private var status
    @State private var otherExpanded: Bool

    init(showsOther: Bool = false) {
        self.showsOther = showsOther
        _otherExpanded = State(initialValue: showsOther)
    }

    var body: some View {
        @Bindable var settings = settings
        let trusted = status.accessibilityTrusted

        if trusted {
            HotkeyRecorderRow(target: .single, title: "快捷鍵", caption: "單鍵・說完直接貼上", note: singleNote)
        } else {
            HotkeyRecorderRow(target: .combination, title: "快捷鍵", caption: "組合鍵・說完按 ⌘V 貼上", note: comboNote)
        }

        Picker(selection: $settings.hotkey.mode) {
            ForEach(TriggerMode.allCases) { mode in
                Text(mode.shortName).tag(mode)
            }
        } label: {
            RowTitle("操作方式", caption: settings.hotkey.mode.displayName)
        }
        .pickerStyle(.segmented)

        variantPicker("說話改字", caption: trusted ? "選取文字後，按住它再按快捷鍵" : "需要自動貼上",
                      selection: $settings.hotkey.editModifier)
        variantPicker("翻譯", caption: "按住它再按快捷鍵", selection: $settings.hotkey.translateModifier)

        DisclosureGroup(isExpanded: $otherExpanded) {
            if trusted {
                HotkeyRecorderRow(target: .combination, title: "組合鍵", caption: "沒有輔助使用權限時使用", note: comboNote)
            } else {
                HotkeyRecorderRow(target: .single, title: "單鍵", caption: "開啟自動貼上後改用這個", note: singleNote)
            }
        } label: {
            Text(trusted ? "備用組合鍵" : "單鍵快捷鍵")
                .foregroundStyle(.secondary)
        }
    }

    /// Under the single-key row: not active yet, or a setting the key needs.
    private var singleNote: RowNote? {
        if status.needsRelaunch {
            return RowNote(text: "還沒生效，暫時用 \(settings.hotkey.combo.displayName)", isProblem: true)
        }
        switch settings.hotkey.trigger.kind {
        case .fn:
            return RowNote(text: "要把「按下 🌐 鍵時」設成「不做任何事」", isProblem: true,
                           linkTitle: "鍵盤設定", link: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
        case .function:
            return RowNote(text: "筆電可能要同時按住 fn", isProblem: false)
        case .modifier:
            return nil
        }
    }

    /// Under the combination row: taken by another app or macOS.
    private var comboNote: RowNote? {
        guard case .taken(let conflict) = status.hotkey.combo else { return nil }
        return RowNote(text: "\(conflict.label)，請更改", isProblem: true)
    }

    @ViewBuilder
    private func variantPicker(_ title: String, caption: String, selection: Binding<VariantModifier>) -> some View {
        let problem = settings.hotkey.problem(for: selection.wrappedValue)
        Picker(selection: selection) {
            ForEach(VariantModifier.allCases) { modifier in
                Text(modifier == .none ? "不使用" : modifier.displayName).tag(modifier)
            }
        } label: {
            RowTitle(title, caption: problem ?? caption, captionIsProblem: problem != nil)
        }
        .pickerStyle(.menu)
    }
}

/// A row title with a short secondary line under it (terracotta when it is a problem).
struct RowTitle: View {
    let title: String
    var caption: String?
    var captionIsProblem = false

    init(_ title: String, caption: String? = nil, captionIsProblem: Bool = false) {
        self.title = title
        self.caption = caption
        self.captionIsProblem = captionIsProblem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(captionIsProblem ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A line under a hotkey row, with an optional link.
struct RowNote: Equatable {
    var text: String
    var isProblem: Bool
    var linkTitle: String?
    var link: URL?
}

// MARK: - Recorder

/// A hotkey row: title and caption on the left; the keys as keycaps and 更改 on the right.
/// 更改 (or a click on the keys) listens inside this window — no permission needed, the global
/// hotkey is paused meanwhile — for the next key(s); Esc cancels. Rejections are explained in the
/// caption line, in a few words.
///
/// - `.single`: one key pressed and released on its own — any modifier on either side, Fn/🌐, or
///   F1–F20. Typing keys and Caps Lock are refused.
/// - `.combination`: ⌘, ⌃ or ⌥ (⇧ optional) plus one key, or an F-key alone. Clashes are reported
///   by the hotkey monitor after saving (`HotkeyRuntime`).
struct HotkeyRecorderRow: View {
    enum Target {
        case single, combination
    }

    /// A short result under the title after a key press.
    enum Feedback: Equatable {
        case rejected(String)
        case saved
    }

    /// Start state, for snapshot renders.
    enum Phase: Equatable {
        case idle
        case listening
        /// Still listening, after a key that cannot be used.
        case rejected(String)
        case saved
    }

    let target: Target
    let title: String
    var caption: String?
    var note: RowNote?

    @Environment(MacSettings.self) private var settings
    @Environment(EngineStatus.self) private var status
    @State private var listening: Bool
    @State private var feedback: Feedback?
    @State private var held: Set<ModifierFamily> = []
    @State private var monitor: Any?
    @State private var timeout: DispatchWorkItem?
    @State private var pressedModifier: UInt16?
    @State private var dirty = false
    @State private var hovering = false

    init(target: Target, title: String, caption: String? = nil, note: RowNote? = nil, initialPhase: Phase = .idle) {
        self.target = target
        self.title = title
        self.caption = caption
        self.note = note
        switch initialPhase {
        case .idle:
            _listening = State(initialValue: false)
            _feedback = State(initialValue: nil)
        case .listening:
            _listening = State(initialValue: true)
            _feedback = State(initialValue: nil)
        case .rejected(let message):
            _listening = State(initialValue: true)
            _feedback = State(initialValue: .rejected(message))
        case .saved:
            _listening = State(initialValue: false)
            _feedback = State(initialValue: .saved)
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                keys
                Button(listening ? "取消" : "更改") {
                    listening ? stop(feedback: nil) : start()
                }
                .buttonStyle(.bordered)
                .help(listening ? "取消（esc）" : "按一下，再按下新的快捷鍵")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                captionLine
            }
        }
        .onDisappear { stop(feedback: nil) }
    }

    // MARK: Pieces

    private var currentKeycaps: [String] {
        switch target {
        case .single: [settings.hotkey.trigger.shortName]
        case .combination: settings.hotkey.combo.keycaps
        }
    }

    @ViewBuilder
    private var keys: some View {
        Button {
            listening ? stop(feedback: nil) : start()
        } label: {
            Group {
                if listening {
                    HStack(spacing: 4) {
                        ForEach(KeyCombo.displayOrder.filter { held.contains($0) }, id: \.self) { family in
                            Keycap(text: family.symbol)
                        }
                        Text(held.isEmpty ? "按下想用的鍵…" : "…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    )
                } else {
                    KeycapGroup(keycaps: currentKeycaps)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(listening ? "正在等你按下新的快捷鍵" : "\(title)：\(currentKeycaps.joined(separator: " "))")
        .accessibilityHint("按一下更改")
    }

    @ViewBuilder
    private var captionLine: some View {
        if let feedback {
            switch feedback {
            case .rejected(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.accentText)
            case .saved:
                Label("已設定", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } else if listening {
            Text(target == .single ? "修飾鍵（左右都可以）、Fn 或 F1–F20・esc 取消" : "⌘ ⌃ ⌥ 加一個鍵，或單獨的 F 鍵・esc 取消")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let note {
            HStack(spacing: 6) {
                Text(note.text)
                    .foregroundStyle(note.isProblem ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
                if let title = note.linkTitle, let link = note.link {
                    Button(title) { NSWorkspace.shared.open(link) }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
        } else if let caption {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Listening

    private func start() {
        held = []
        pressedModifier = nil
        dirty = false
        feedback = nil
        listening = true
        status.pauseHotkey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil // nothing else in the window reacts while listening
        }
        let work = DispatchWorkItem { stop(feedback: .rejected("沒有收到按鍵")) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func handle(_ event: NSEvent) {
        let modifiers = Self.families(in: event.modifierFlags)
        if event.type == .keyDown, event.keyCode == KeyCodes.escape, modifiers.isEmpty {
            stop(feedback: nil)
            return
        }
        switch target {
        case .single: handleSingle(event, modifiers: modifiers)
        case .combination: handleCombination(event, modifiers: modifiers)
        }
    }

    /// One key on its own: a modifier is taken when it is released with nothing else pressed; an
    /// F-key is taken on key down. Anything else is explained and listening goes on.
    private func handleSingle(_ event: NSEvent, modifiers: Set<ModifierFamily>) {
        if event.type == .keyDown {
            if TriggerKey.from(keyCode: event.keyCode)?.isFunctionKey == true, modifiers.isEmpty, pressedModifier == nil {
                save(trigger: TriggerKey.from(keyCode: event.keyCode))
                return
            }
            dirty = true
            if pressedModifier != nil || !modifiers.isEmpty {
                feedback = .rejected("只按一個鍵")
            } else {
                feedback = .rejected(Self.message(for: TriggerKey.rejection(forKeyCode: event.keyCode) ?? .typingKey))
            }
            return
        }
        // flagsChanged
        held = modifiers
        if event.keyCode == KeyCodes.capsLock {
            feedback = .rejected(Self.message(for: .capsLock))
            return
        }
        let anyHeld = !modifiers.isEmpty || event.modifierFlags.contains(.function)
        if let pressed = pressedModifier {
            if event.keyCode != pressed { dirty = true }
            guard !anyHeld else { return }
            pressedModifier = nil
            if dirty {
                dirty = false
                feedback = .rejected("只按一個鍵")
            } else {
                save(trigger: TriggerKey.from(keyCode: pressed))
            }
        } else if anyHeld, TriggerKey.from(keyCode: event.keyCode) != nil {
            pressedModifier = event.keyCode
            dirty = false
            feedback = nil
        }
    }

    private func handleCombination(_ event: NSEvent, modifiers: Set<ModifierFamily>) {
        if event.type == .flagsChanged {
            held = modifiers
            return
        }
        switch KeyCombo.problem(keyCode: event.keyCode, modifiers: modifiers) {
        case .needsModifier?:
            feedback = .rejected("要加上 ⌘、⌃ 或 ⌥")
            return
        case .reserved?:
            feedback = .rejected("esc 用來取消，換一個鍵")
            return
        case nil:
            break
        }
        let label = KeyCombo.specialKeyLabel(for: event.keyCode)
            ?? event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let label, !label.isEmpty else {
            feedback = .rejected("這個鍵不能用")
            return
        }
        settings.hotkey.combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label)
        stop(feedback: .saved)
    }

    private func save(trigger: TriggerKey?) {
        guard let trigger else {
            feedback = .rejected("這個鍵不能用")
            return
        }
        settings.hotkey.trigger = trigger
        stop(feedback: .saved)
    }

    private func stop(feedback newFeedback: Feedback?) {
        timeout?.cancel()
        timeout = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if listening { status.pauseHotkey(false) }
        held = []
        pressedModifier = nil
        withAnimation(.easeOut(duration: 0.15)) {
            listening = false
            feedback = newFeedback
        }
        if let newFeedback {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if feedback == newFeedback, !listening { withAnimation { feedback = nil } }
            }
        }
    }

    static func message(for rejection: TriggerKey.Rejection) -> String {
        switch rejection {
        case .capsLock: "Caps Lock 會切換大小寫，不能用"
        case .escape: "esc 用來取消，換一個鍵"
        case .typingKey: "一般按鍵打字時會觸發，請用修飾鍵或 F 鍵"
        }
    }

    static func families(in flags: NSEvent.ModifierFlags) -> Set<ModifierFamily> {
        var families = Set<ModifierFamily>()
        if flags.contains(.command) { families.insert(.command) }
        if flags.contains(.control) { families.insert(.control) }
        if flags.contains(.option) { families.insert(.option) }
        if flags.contains(.shift) { families.insert(.shift) }
        return families
    }
}

/// The combination recorder in a small popover (試一次).
struct ComboRecorderPopover: View {
    @Environment(EngineStatus.self) private var status
    @Environment(MacSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("換一組快捷鍵").font(.headline)
            HotkeyRecorderRow(target: .combination, title: "組合鍵", caption: "例如 ⌃⌥ Space",
                              note: comboNote)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private var comboNote: RowNote? {
        guard case .taken(let conflict) = status.hotkey.combo else { return nil }
        return RowNote(text: "\(settings.hotkey.combo.displayName) \(conflict.label)", isProblem: true)
    }
}
