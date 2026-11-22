import AppKit
import SwiftUI
import XCTest
import ScriberCore
import ScriberShared

/// 模式 (docs/PRD-模式.md, M2): the list, the editor in each state, prompts, the icon grid, the HUD
/// with a mode's icon, and 設定 → 快捷鍵 after the variant pickers moved. Light and dark; files start
/// with `16-modes-`. Stores are on temporary files; nothing touches the app's data, no hotkey is
/// registered.
@MainActor
final class ModesSnapshotTests: XCTestCase {
    private let mainSize = CGSize(width: WindowManager.mainDefaultSize.width, height: WindowManager.mainDefaultSize.height)
    private let mainSmall = CGSize(width: WindowManager.mainMinimumSize.width, height: WindowManager.mainMinimumSize.height)
    /// The detail column alone (the sidebar is 210 wide).
    private var detailWidth: CGFloat { mainSize.width - 210 }

    // MARK: Sample data

    private func modeStore() -> ModeStore {
        ModeStore(fileURL: Sample.folder.appendingPathComponent("modes-\(UUID().uuidString).json"))
    }

    private func promptLibrary() -> PromptLibrary {
        PromptLibrary(fileURL: Sample.folder.appendingPathComponent("prompts-\(UUID().uuidString).json"))
    }

    private static let meetingID = "sample.meeting"
    private static let codeID = "sample.code"

    /// Two modes of the user's (one with its own combination, one whose hotkey clashes with 改寫),
    /// Email as the default, 助理 off, and an edited Email prompt plus one prompt of the user's.
    private func customized() throws -> (ModeStore, PromptLibrary) {
        let store = modeStore()
        let library = promptLibrary()
        var email = PromptLibrary.builtIn(.email)
        email.body += "\n10. 結尾不要加「祝好」。"
        try library.update(email)
        let mine = try library.add(name: "程式註解", kind: .dictation, body: "- 保留英文術語。\n\n# 整理方式\n1. 寫成一行簡短的英文註解。")
        store.add(DictationModeConfig(
            id: Self.meetingID, name: "會議筆記", icon: "person.2",
            trigger: ModeTrigger(hotkey: ModeShortcut.combination(KeyCombo(keyCode: 0x2E, modifiers: [.control, .option],
                                                                           keyLabel: "M")).modeHotkey),
            recognition: ModeRecognition(engine: .custom(.groqWhisperTurbo)),
            ai: ModeAI(enabled: .custom(true), provider: .custom(.anthropic), promptID: BuiltInPromptID.meeting.rawValue)))
        store.add(DictationModeConfig(
            id: Self.codeID, name: "寫程式", icon: "chevron.left.forwardslash.chevron.right",
            trigger: ModeTrigger(hotkey: .withMainTrigger("shift")),
            recognition: ModeRecognition(language: .custom("en")),
            textFormat: ModeTextFormat(forceTraditional: .custom(false), spaceBetweenCJKAndLatin: .custom(true),
                                       punctuationRule: .custom(.keep), punctuationLimit: .custom(20)),
            ai: ModeAI(enabled: .custom(true), promptID: mine.id)))
        try store.setDefault(id: BuiltInModeID.email.rawValue)
        try store.setEnabled(false, id: BuiltInModeID.assistant.rawValue)
        return (store, library)
    }

    private func page(_ store: ModeStore, _ library: PromptLibrary, settings: MacSettings, status: EngineStatus) -> some View {
        var data = Sample.sources(history: Sample.history([]), stats: Sample.stats)
        data.modes = store
        data.prompts = library
        return mainWindow(.modes, settings: settings, status: status, data: data)
    }

    private func editor(_ id: String, store: ModeStore, library: PromptLibrary, settings: MacSettings,
                        status: EngineStatus, recording: Bool = false) -> some View {
        ModeEditorView(modeID: id, store: store, prompts: library, onBack: {}, startsRecording: recording)
            .environment(settings)
            .environment(status)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var registered: HotkeyRuntimeState {
        HotkeyRuntimeState(active: .single(.rightOption), combo: .off, modeCombos: [Self.meetingID: .registered])
    }

    // MARK: List

    func testModesList() throws {
        let fresh = modeStore()
        let freshPrompts = promptLibrary()
        try SnapshotRenderer.renderBoth("16-modes-1-list-shipped", size: mainSize) {
            page(fresh, freshPrompts, settings: Sample.settings(), status: Sample.status())
        }
        let (store, library) = try customized()
        let ax = EngineStatus(sample: .granted, accessibilityTrusted: true, hotkey: registered)
        try SnapshotRenderer.renderBoth("16-modes-2-list-customized", size: CGSize(width: mainSize.width, height: 820)) {
            page(store, library, settings: Sample.settings(polish: .groq), status: ax)
        }
        try SnapshotRenderer.renderBoth("16-modes-3-list-small", size: mainSmall) {
            page(store, library, settings: Sample.settings(polish: .groq), status: ax)
        }
        // A hovered card (the "…" appears) and a card being dropped on.
        try SnapshotRenderer.renderBoth("16-modes-4-card-hover", size: CGSize(width: 760, height: 170), chrome: false) {
            VStack(spacing: 8) {
                ModeCard(mode: DictationModeConfig.builtIn(.rewrite), isCurrent: false,
                         tags: [.init(symbol: "waveform", text: "Scribe v3"), .init(symbol: "sparkles", text: "Groq"),
                                .init(symbol: "text.quote", text: "改寫")],
                         keycaps: ["⇧", "右 ⌥"], problem: nil, canTurnOff: true, onOpen: {}, onToggle: { _ in }) {
                    Button("編輯…") {}
                }
                .environment(\.forcedHover, true)
                ModeCard(mode: DictationModeConfig(name: "寫程式", icon: "chevron.left.forwardslash.chevron.right"),
                         isCurrent: false, tags: [.init(symbol: "waveform", text: "Scribe v3"), .init(symbol: nil, text: "不用 AI")],
                         keycaps: ["⇧", "右 ⌥"], problem: "跟「改寫」重複", canTurnOff: true, isDropTarget: true,
                         onOpen: {}, onToggle: { _ in }) {
                    Button("編輯…") {}
                }
            }
            .padding(20)
        }
        // No AI key at all, no Accessibility: 改寫 needs automatic paste on the combination path.
        try SnapshotRenderer.renderBoth("16-modes-5-list-no-ai-key", size: mainSize) {
            page(modeStore(), promptLibrary(), settings: Sample.settings(keys: [.elevenLabs]), status: Sample.status())
        }
    }

    // MARK: Editor

    func testModeEditor() throws {
        let tall = CGSize(width: detailWidth, height: 1180)
        let fresh = modeStore()
        let freshPrompts = promptLibrary()
        try SnapshotRenderer.renderBoth("16-modes-6-editor-dictate", size: tall) {
            editor(BuiltInModeID.dictate.rawValue, store: fresh, library: freshPrompts, settings: Sample.settings(),
                   status: Sample.status(trusted: true))
        }
        try SnapshotRenderer.renderBoth("16-modes-7-editor-translate", size: tall) {
            editor(BuiltInModeID.translate.rawValue, store: fresh, library: freshPrompts, settings: Sample.settings(),
                   status: Sample.status(trusted: true))
        }
        // 改寫 without Accessibility: its hotkey only works with automatic paste.
        try SnapshotRenderer.renderBoth("16-modes-8-editor-rewrite-no-ax", size: tall) {
            editor(BuiltInModeID.rewrite.rawValue, store: fresh, library: freshPrompts, settings: Sample.settings(),
                   status: Sample.status())
        }
        let (store, library) = try customized()
        let ax = EngineStatus(sample: .granted, accessibilityTrusted: true, hotkey: registered)
        try SnapshotRenderer.renderBoth("16-modes-9-editor-custom-combo", size: CGSize(width: detailWidth, height: 1300)) {
            editor(Self.meetingID, store: store, library: library, settings: Sample.settings(polish: .groq), status: ax)
        }
        try SnapshotRenderer.renderBoth("16-modes-10-editor-custom-format-conflict", size: CGSize(width: detailWidth, height: 1400)) {
            editor(Self.codeID, store: store, library: library, settings: Sample.settings(polish: .groq), status: ax)
        }
        // Choosing 自己的組合鍵 for the first time: the recorder listens right away.
        try SnapshotRenderer.renderBoth("16-modes-11-editor-recording-combo", size: CGSize(width: detailWidth, height: 520)) {
            editor(BuiltInModeID.email.rawValue, store: store, library: library, settings: Sample.settings(polish: .groq),
                   status: ax, recording: true)
        }
        // The combination was taken by another app.
        let taken = EngineStatus(sample: .granted, accessibilityTrusted: true,
                                 hotkey: HotkeyRuntimeState(active: .single(.rightOption), combo: .off,
                                                            modeCombos: [Self.meetingID: .taken(.otherApp)]))
        try SnapshotRenderer.renderBoth("16-modes-12-editor-combo-taken", size: CGSize(width: detailWidth, height: 520)) {
            editor(Self.meetingID, store: store, library: library, settings: Sample.settings(polish: .groq), status: taken)
        }
        // The engine and AI keys are missing.
        try SnapshotRenderer.renderBoth("16-modes-13-editor-missing-keys", size: CGSize(width: detailWidth, height: 1300)) {
            editor(Self.meetingID, store: store, library: library, settings: Sample.settings(keys: [.elevenLabs]), status: ax)
        }
    }

    /// Small window: the editor must scroll, never clip.
    func testModeEditorSmall() throws {
        let (store, library) = try customized()
        try SnapshotRenderer.renderBoth("16-modes-14-editor-small", size: CGSize(width: mainSmall.width - 210, height: mainSmall.height)) {
            editor(Self.meetingID, store: store, library: library, settings: Sample.settings(polish: .groq),
                   status: EngineStatus(sample: .granted, accessibilityTrusted: true, hotkey: registered))
        }
    }

    // MARK: Prompts

    func testPrompts() throws {
        let (store, library) = try customized()
        try SnapshotRenderer.renderBoth("16-modes-15-prompt-library", size: CGSize(width: 520, height: 560), chrome: false) {
            PromptLibraryView(library: library, modes: store, forcedHoverID: BuiltInPromptID.email.rawValue)
        }
        try SnapshotRenderer.renderBoth("16-modes-16-prompt-edit-builtin", size: CGSize(width: 560, height: 520), chrome: false) {
            PromptEditorView(target: PromptEditorTarget(promptID: BuiltInPromptID.email.rawValue), library: library, modes: store)
        }
        let mine = try XCTUnwrap(library.prompts.first { !$0.isBuiltIn })
        try SnapshotRenderer.renderBoth("16-modes-17-prompt-edit-mine", size: CGSize(width: 560, height: 480), chrome: false) {
            PromptEditorView(target: PromptEditorTarget(promptID: mine.id), library: library, modes: store)
        }
        try SnapshotRenderer.renderBoth("16-modes-18-prompt-new", size: CGSize(width: 560, height: 520), chrome: false) {
            PromptEditorView(target: PromptEditorTarget(promptID: nil), library: library, modes: store)
        }
    }

    // MARK: Pieces

    func testIconGridAndInfo() throws {
        try SnapshotRenderer.renderBoth("16-modes-19-icon-grid", size: CGSize(width: 260, height: 290), chrome: false) {
            ModeIconGrid(selection: .constant("person.2"))
        }
        // What the "?" buttons say (popovers cannot be captured).
        try SnapshotRenderer.renderBoth("16-modes-20-info", size: CGSize(width: 332, height: 520), chrome: false) {
            VStack(alignment: .leading, spacing: 10) {
                InfoText(ModesView.info)
                Divider()
                InfoItem(title: "按住修飾鍵再按快捷鍵", text: "例如按住 ⇧ 再按快捷鍵。有沒有開自動貼上都能用。")
                InfoItem(title: "自己的組合鍵", text: "例如 ⌃⌥M，或單獨一個 F 鍵。不需要任何權限，隨時可用。")
                InfoText("點一下或按住，跟主要快捷鍵的操作方式一樣。")
                Divider()
                InfoItem(title: "{{language}}", text: "翻譯的目標語言")
                InfoItem(title: "{{spacing}}", text: "中英文之間要不要空格（照模式的文字格式）")
                InfoItem(title: "{{selected}}", text: "選取的文字（改寫類）")
                InfoText("Scriber 會在外面加上固定的規則：說的話只當成要整理的內容，不會被當成指令、不會被回答；只輸出結果。這部分不能改，寫在這裡的也蓋不過它。")
            }
            .font(.callout).frame(width: 300, alignment: .leading).padding(16)
        }
    }

    /// The HUD while recording: plain 聽寫 (nothing), a mode's icon, translate's language.
    func testHUD() throws {
        let states: [(String, HUDState)] = [
            ("dictate", .recording(.dictate, badge: nil, symbol: nil)),
            ("mode-icon", .recording(.dictate, badge: nil, symbol: "person.2")),
            ("translate", .recording(.translate, badge: "EN", symbol: "translate")),
            ("processing-icon", .processing(.dictate, symbol: "envelope")),
        ]
        for (name, state) in states {
            try SnapshotRenderer.renderBoth("16-modes-21-hud-\(name)", size: CGSize(width: 300, height: 76), chrome: false) {
                let model = HUDModel()
                model.state = state
                return HUDView(model: model)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    /// 設定 → 快捷鍵: the 說話改字 / 翻譯 pop-ups are gone; one row lists the modes' hotkeys.
    func testSettingsHotkeys() throws {
        let store = modeStore()
        let library = promptLibrary()
        try SnapshotRenderer.renderBoth("16-modes-22-settings-hotkeys", size: CGSize(width: 700, height: 360), chrome: false) {
            Form {
                Section {
                    HotkeySettingsView()
                } header: {
                    Text("快捷鍵")
                }
            }
            .formStyle(.grouped)
            .environment(Sample.settings())
            .environment(Sample.status(trusted: true))
            .environment(store)
            .environment(library)
            .environment(MainNavigation())
        }
        let data = Sample.sources(history: Sample.history([]), stats: Sample.stats)
        try SnapshotRenderer.renderBoth("16-modes-23-settings-page", size: CGSize(width: 980, height: 1400)) {
            mainWindow(.settings, settings: Sample.settings(), status: Sample.status(trusted: true), data: data)
        }
    }

    func testSidebar() throws {
        try SnapshotRenderer.renderBoth("16-modes-24-sidebar", size: CGSize(width: 220, height: 560)) {
            let navigation = MainNavigation()
            navigation.section = .modes
            return MainSidebar(attention: false)
                .environment(navigation)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    /// Every SF Symbol the modes UI offers or uses must exist (a missing name draws nothing).
    func testModeSymbolsExist() {
        let names = ModeIconGrid.symbols + DictationModeConfig.builtIns.map(\.icon)
            + ["rectangle.stack", "rectangle.stack.fill", "text.quote", "ellipsis", "chevron.left", "star", "arrow.right",
               "waveform", "sparkles", "globe", "exclamationmark.triangle.fill", "plus"]
        XCTAssertEqual(names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }, [])
    }
}
