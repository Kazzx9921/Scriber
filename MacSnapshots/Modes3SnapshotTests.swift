import AppKit
import SwiftUI
import XCTest
import ScriberCore
import ScriberShared

/// 模式 M3 (docs/PRD-模式.md §4, §7.2, §7.5–7.7): 自動套用的 App, 情境, the output picker and
/// 自動送出 in the editor; the tags on the list; the answer panel; the 只複製 pill; the "?" texts.
/// Light and dark; files start with `17-modes3-`. Stores are on temporary files; app names and icons
/// come from Launch Services (system apps only, so every Mac renders the same rows).
@MainActor
final class Modes3SnapshotTests: XCTestCase {
    private let mainSize = CGSize(width: WindowManager.mainDefaultSize.width, height: WindowManager.mainDefaultSize.height)
    private let mainSmall = CGSize(width: WindowManager.mainMinimumSize.width, height: WindowManager.mainMinimumSize.height)
    private var detailWidth: CGFloat { mainSize.width - 210 }

    private static let chatID = "sample.chat"
    private static let notesID = "sample.notes"

    private func modeStore() -> ModeStore {
        ModeStore(fileURL: Sample.folder.appendingPathComponent("modes-\(UUID().uuidString).json"))
    }

    private func promptLibrary() -> PromptLibrary {
        PromptLibrary(fileURL: Sample.folder.appendingPathComponent("prompts-\(UUID().uuidString).json"))
    }

    /// A chat mode that sends with Return in Messages; a notes mode listing Mail (after Email, so
    /// Email wins there), Notes, and an app that is not installed, with every context switch on and
    /// copy-only output; 助理 as shipped (answer panel).
    private func customized() throws -> (ModeStore, PromptLibrary) {
        let store = modeStore()
        let library = promptLibrary()
        store.add(DictationModeConfig(
            id: Self.chatID, name: "聊天", icon: "bubble.left.and.bubble.right",
            trigger: ModeTrigger(appBundleIDs: ["com.apple.MobileSMS"]),
            ai: ModeAI(enabled: .custom(true), promptID: BuiltInPromptID.standard.rawValue),
            autoSend: .returnKey))
        store.add(DictationModeConfig(
            id: Self.notesID, name: "重點筆記", icon: "list.bullet",
            trigger: ModeTrigger(appBundleIDs: ["com.apple.mail", "com.apple.Notes", "com.example.removed"]),
            ai: ModeAI(enabled: .custom(true), promptID: BuiltInPromptID.bullets.rawValue),
            context: ModeContextFlags(selectedText: true, clipboard: true, appName: true),
            output: .copyOnly))
        return (store, library)
    }

    private func editor(_ id: String, store: ModeStore, library: PromptLibrary, settings: MacSettings,
                        status: EngineStatus, hover: Bool = false) -> some View {
        ModeEditorView(modeID: id, store: store, prompts: library, onBack: {})
            .environment(settings)
            .environment(status)
            .environment(\.forcedHover, hover)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var ax: EngineStatus { Sample.status(trusted: true) }

    // MARK: Editor

    func testEditor() throws {
        let tall = CGSize(width: detailWidth, height: 1500)
        // A new install: Email lists Mail; a Groq key is there.
        let fresh = modeStore()
        let freshPrompts = promptLibrary()
        try SnapshotRenderer.renderBoth("17-modes3-1-editor-email", size: tall) {
            editor(BuiltInModeID.email.rawValue, store: fresh, library: freshPrompts, settings: Sample.settings(), status: ax)
        }
        // No AI key: Email cannot run in Mail, the default mode does.
        try SnapshotRenderer.renderBoth("17-modes3-2-editor-email-no-key", size: CGSize(width: detailWidth, height: 560)) {
            editor(BuiltInModeID.email.rawValue, store: fresh, library: freshPrompts,
                   settings: Sample.settings(keys: [.elevenLabs]), status: ax)
        }
        // An existing install after the update: Email without Mail.
        let existing = modeStore()
        var email = DictationModeConfig.builtIn(.email)
        email.trigger.appBundleIDs = []
        try existing.update(email)
        try SnapshotRenderer.renderBoth("17-modes3-3-editor-email-existing", size: CGSize(width: detailWidth, height: 520)) {
            editor(BuiltInModeID.email.rawValue, store: existing, library: freshPrompts, settings: Sample.settings(), status: ax)
        }
        // 助理: the answer panel; 情境 off.
        try SnapshotRenderer.renderBoth("17-modes3-4-editor-assistant", size: tall) {
            editor(BuiltInModeID.assistant.rawValue, store: fresh, library: freshPrompts, settings: Sample.settings(), status: ax)
        }
        // 改寫: the selection is always sent.
        try SnapshotRenderer.renderBoth("17-modes3-5-editor-rewrite", size: tall) {
            editor(BuiltInModeID.rewrite.rawValue, store: fresh, library: freshPrompts, settings: Sample.settings(), status: ax)
        }
        let (store, library) = try customized()
        // Apps (one taken by Email, one not installed; hover shows remove), every context switch, copy only.
        try SnapshotRenderer.renderBoth("17-modes3-6-editor-apps-context-copy", size: tall) {
            editor(Self.notesID, store: store, library: library, settings: Sample.settings(), status: ax, hover: true)
        }
        // Same without Accessibility: the selection needs it.
        try SnapshotRenderer.renderBoth("17-modes3-7-editor-context-no-ax", size: CGSize(width: detailWidth, height: 1500)) {
            editor(Self.notesID, store: store, library: library, settings: Sample.settings(), status: Sample.status())
        }
        // 自動送出 on: the one warning line; without Accessibility it says what is missing.
        try SnapshotRenderer.renderBoth("17-modes3-8-editor-autosend", size: tall) {
            editor(Self.chatID, store: store, library: library, settings: Sample.settings(), status: ax)
        }
        try SnapshotRenderer.renderBoth("17-modes3-9-editor-autosend-no-ax", size: tall) {
            editor(Self.chatID, store: store, library: library, settings: Sample.settings(), status: Sample.status())
        }
    }

    func testEditorSmall() throws {
        let (store, library) = try customized()
        try SnapshotRenderer.renderBoth("17-modes3-10-editor-small", size: CGSize(width: mainSmall.width - 210, height: mainSmall.height)) {
            editor(Self.notesID, store: store, library: library, settings: Sample.settings(), status: ax)
        }
    }

    // MARK: List

    func testList() throws {
        let (store, library) = try customized()
        var data = Sample.sources(history: Sample.history([]), stats: Sample.stats)
        data.modes = store
        data.prompts = library
        try SnapshotRenderer.renderBoth("17-modes3-11-list", size: CGSize(width: mainSize.width, height: 900)) {
            mainWindow(.modes, settings: Sample.settings(), status: ax, data: data)
        }
    }

    // MARK: Answer panel and HUD

    private func answer(_ text: String, question: String?, maxHeight: CGFloat = AnswerLayout.maxBodyHeight,
                        copied: Bool = false) -> (AnswerModel, CGSize) {
        let model = AnswerModel()
        model.answer = text
        model.question = question
        model.title = "助理"
        model.symbol = "bubble.left.and.text.bubble.right"
        model.copied = copied
        model.bodyHeight = AnswerLayout.bodyHeight(for: text, maxHeight: maxHeight)
        return (model, AnswerLayout.panelSize(bodyHeight: model.bodyHeight, question: question))
    }

    func testAnswerPanel() throws {
        let short = answer("台北到高雄搭高鐵最快大約 1 小時 35 分，直達車；一般停靠的班次大約 2 小時。",
                           question: "台北到高雄搭高鐵要多久")
        try SnapshotRenderer.renderBoth("17-modes3-12-answer-short", size: short.1, chrome: false) {
            AnswerPanelView(model: short.0)
        }
        let long = answer("""
        可以分三步做：

        1. 先在「設定 → 快捷鍵」確認主要快捷鍵能用，按一下看看浮動膠囊有沒有出現。
        2. 到「模式」新增一個模式，引擎跟隨預設，AI 整理打開，提示詞選「條列重點」。
        3. 在「觸發 → 自動套用」加入你常用的筆記 App，之後在那個 App 裡按主要快捷鍵，就會自動用這個模式。

        如果要讓 AI 參考你剛剛複製的內容，在「情境」打開剪貼簿。密碼管理器複製的密碼不會被送出去。

        最後，結果想先看過再決定要不要貼，可以把「輸出 → 結果」改成「顯示在面板」，就像現在這樣。面板不會搶走游標，按 esc 就關掉。
        """, question: "我要怎麼設定一個在筆記 App 自動整理重點的模式？順便告訴我怎麼讓它參考剪貼簿")
        try SnapshotRenderer.renderBoth("17-modes3-13-answer-long", size: long.1, chrome: false) {
            AnswerPanelView(model: long.0)
        }
        let copied = answer("Thank you for the update. I'll review the draft and get back to you by Friday.", question: nil,
                            copied: true)
        try SnapshotRenderer.renderBoth("17-modes3-14-answer-copied-no-question", size: copied.1, chrome: false) {
            AnswerPanelView(model: copied.0)
        }
    }

    func testHUD() throws {
        let states: [(String, HUDState)] = [
            ("copied-only", .feedback(.copiedOnly)),
            ("auto-applied-email", .recording(.dictate, badge: nil, symbol: "envelope")),
        ]
        for (name, state) in states {
            try SnapshotRenderer.renderBoth("17-modes3-15-hud-\(name)", size: CGSize(width: 300, height: 76), chrome: false) {
                let model = HUDModel()
                model.state = state
                return HUDView(model: model)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    // MARK: "?" texts (popovers cannot be captured)

    func testInfo() throws {
        try SnapshotRenderer.renderBoth("17-modes3-16-info-trigger-context", size: CGSize(width: 332, height: 470), chrome: false) {
            VStack(alignment: .leading, spacing: 10) {
                ModeEditorView.triggerHelp
                Divider()
                ModeEditorView.contextHelp
            }
            .font(.callout).frame(width: 300, alignment: .leading).padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        try SnapshotRenderer.renderBoth("17-modes3-17-info-output-variables", size: CGSize(width: 332, height: 580), chrome: false) {
            VStack(alignment: .leading, spacing: 10) {
                ModeEditorView.outputHelp
                Divider()
                PromptEditorView.variablesHelp(kind: .dictation)
            }
            .font(.callout).frame(width: 300, alignment: .leading).padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    func testSymbolsExist() {
        let names = ["macwindow", "doc.on.doc", "text.bubble", "return", "minus.circle.fill", "app.dashed", "checkmark",
                     "xmark", "bubble.left.and.text.bubble.right", "bubble.left.and.bubble.right", "list.bullet", "envelope"]
        XCTAssertEqual(names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }, [])
    }
}
