import XCTest
@testable import ScriberCore
import ScriberShared

/// `KeyboardModes`: the iOS keyboard's mode key (docs/PRD-模式.md §6.2, M4) — tap cycling and
/// recents, what the long press offers, the request the mic sends, the fallback when the store
/// cannot be read, and the outputs iOS does not have.
final class KeyboardModesTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var suiteName: String!
    private var recents: UserDefaults!

    private let dictate = BuiltInModeID.dictate.rawValue
    private let polish = BuiltInModeID.polish.rawValue
    private let translate = BuiltInModeID.translate.rawValue
    private let rewrite = BuiltInModeID.rewrite.rawValue
    private let email = BuiltInModeID.email.rawValue
    private let assistant = BuiltInModeID.assistant.rawValue

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberKeyboardModes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("modes.json")
        suiteName = "ScriberKeyboardModesTests-\(UUID().uuidString)"
        recents = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        recents.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func defaults(polish: PolishProviderKind = .off) -> ModeDefaults {
        ModeDefaults(sttProvider: .elevenLabsScribe, polishProvider: polish, forceTraditional: true,
                     spaceBetweenCJKAndLatin: true, translateTarget: "English")
    }

    private func state(_ modes: [DictationModeConfig] = DictationModeConfig.builtIns, recents: [String] = [],
                       language: String = "en", hasLLMKey: Bool? = true,
                       prompts: [PromptTemplate] = PromptLibrary.builtIns) -> KeyboardModes.State {
        KeyboardModes.state(modes: modes, prompts: prompts, defaults: defaults(), recents: recents,
                            keyboardLanguageID: language, hasLLMKey: hasLLMKey)
    }

    /// The keyboard's view of a store (the same calls `KeyboardModel` makes).
    private func state(of store: ModeStore, hasLLMKey: Bool? = true) -> KeyboardModes.State {
        KeyboardModes.state(modes: store.snapshot(), prompts: PromptLibrary.builtIns, defaults: defaults(),
                            recents: store.storedRecentIDs, keyboardLanguageID: "en", hasLLMKey: hasLLMKey)
    }

    /// A tap on the mode key.
    private func tap(_ store: ModeStore) {
        guard let partner = state(of: store).partner else { return XCTFail("nothing to switch to") }
        store.noteUsed(id: partner.id)
    }

    // MARK: Starting state = the pre-modes translate key

    func testNothingUsedYetIsDictateAndTranslate() {
        let s = state()
        XCTAssertEqual(s.current?.id, dictate)
        XCTAssertEqual(s.partner?.id, translate, "tap = translate on, as before modes")
        XCTAssertTrue(s.isCalm, "plain dictation draws the key as calm as translate-off")
        XCTAssertEqual(s.baseID, dictate)
        XCTAssertTrue(s.showsKey)
        XCTAssertTrue(s.rewriteOnSelection, "a selection still rewrites it")
        XCTAssertEqual(s.languageItemID, translate, "the long press still lists the quick languages")
        XCTAssertEqual(s.current?.output, .paste)
    }

    // MARK: Tap cycling and recents

    func testTapSwitchesBetweenTheTwoMostRecentModes() {
        let store = ModeStore(fileURL: url, recents: recents)
        XCTAssertEqual(state(of: store).current?.id, dictate)
        tap(store)
        XCTAssertEqual(state(of: store).current?.id, translate)
        XCTAssertEqual(state(of: store).partner?.id, dictate)
        XCTAssertFalse(state(of: store).isCalm)
        tap(store)
        XCTAssertEqual(state(of: store).current?.id, dictate)
        XCTAssertEqual(state(of: store).partner?.id, translate)
        XCTAssertTrue(state(of: store).isCalm)

        // Choosing Email from the long press: the pair is now Email and the mode before it.
        store.noteUsed(id: email)
        XCTAssertEqual(state(of: store).current?.id, email)
        XCTAssertEqual(state(of: store).partner?.id, dictate)
        for expected in [dictate, email, dictate, email] {
            tap(store)
            XCTAssertEqual(state(of: store).current?.id, expected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "switching modes never writes modes.json")
    }

    func testRecentsSkipDeletedDisabledAndRewriteModes() {
        var modes = DictationModeConfig.builtIns
        modes[modes.firstIndex { $0.id == polish }!].isEnabled = false
        let s = state(modes, recents: ["gone-mode", rewrite, polish, email, translate])
        XCTAssertEqual(s.current?.id, email)
        XCTAssertEqual(s.partner?.id, translate)
    }

    func testRecentsWrittenByTheOtherProcessAreSeen() {
        // The app's ModeStore and the keyboard's share the file and the recents defaults.
        let app = ModeStore(fileURL: url, recents: recents)
        let keyboard = ModeStore(fileURL: url, recents: UserDefaults(suiteName: suiteName))
        keyboard.noteUsed(id: translate)
        XCTAssertEqual(app.storedRecentIDs.first, translate)
        // 設為預設 in the app: the default changes and the keyboard switches to it.
        try? app.setDefault(id: email)
        app.noteUsed(id: email)
        let s = state(of: keyboard)
        XCTAssertEqual(s.current?.id, email)
        XCTAssertEqual(s.baseID, email)
        XCTAssertTrue(s.isCalm)
        XCTAssertEqual(s.partner?.id, translate)
        // A mode the app disables drops out of the keyboard.
        try? app.setEnabled(false, id: translate)
        XCTAssertNotEqual(state(of: keyboard).partner?.id, translate)
        XCTAssertFalse(state(of: keyboard).menu.contains { $0.id == translate })
    }

    // MARK: What the keyboard offers

    func testOfferedListOnIOS() {
        let rewriteLike = DictationModeConfig(id: "custom-rewrite", name: "改語氣", icon: "wand.and.stars",
                                              ai: ModeAI(enabled: .custom(true), promptID: BuiltInPromptID.rewrite.rawValue))
        let copyMode = DictationModeConfig(id: "custom-copy", name: "會議重點", icon: "list.bullet",
                                           ai: ModeAI(enabled: .custom(true), promptID: BuiltInPromptID.bullets.rawValue),
                                           output: .copyOnly)
        var modes = DictationModeConfig.builtIns + [rewriteLike, copyMode]
        modes[modes.firstIndex { $0.id == polish }!].isEnabled = false
        let offered = KeyboardModes.offered(modes, prompts: PromptLibrary.builtIns).map(\.id)
        XCTAssertEqual(offered, [dictate, translate, email, assistant, "custom-copy"],
                       "enabled, no rewrite modes; 助理 is offered (its answer is typed)")

        let s = state(modes)
        XCTAssertEqual(s.menu.map(\.id), [dictate, translate, email, assistant], "first four, list order")
        XCTAssertLessThanOrEqual(s.menu.count, KeyboardModes.menuLimit)

        // The current mode is always in the menu, even when it is not among the first four.
        let later = state(modes, recents: ["custom-copy"])
        XCTAssertEqual(later.current?.id, "custom-copy")
        XCTAssertEqual(later.menu.map(\.id), [dictate, translate, email, "custom-copy"])
    }

    func testReorderingInTheAppReordersTheMenu() {
        let store = ModeStore(fileURL: url, recents: recents)
        store.reorder(ids: [email, assistant, translate])
        XCTAssertEqual(state(of: store).menu.map(\.id), [email, assistant, translate, dictate])
    }

    func testTranslateLanguages() {
        var s = state(language: "ja")
        XCTAssertEqual(s.item(id: translate)?.translateLanguageID, "ja", "follows the keyboard's language")
        XCTAssertEqual(s.item(id: translate)?.followsKeyboardLanguage, true)

        var modes = DictationModeConfig.builtIns
        modes[modes.firstIndex { $0.id == translate }!].ai.translateLanguageID = .custom("ko")
        s = state(modes, language: "ja")
        XCTAssertEqual(s.item(id: translate)?.translateLanguageID, "ko", "its own language wins")
        XCTAssertEqual(s.item(id: translate)?.followsKeyboardLanguage, false)
        XCTAssertNil(s.languageItemID, "no quick languages for a mode with its own language")
    }

    func testOnlyTheFirstFollowingTranslateModeListsLanguages() {
        let second = DictationModeConfig(id: "custom-translate", name: "正式英文", icon: "globe",
                                         ai: ModeAI(enabled: .custom(true), promptID: BuiltInPromptID.translate.rawValue))
        let s = state(DictationModeConfig.builtIns.filter { $0.id != polish } + [second])
        XCTAssertEqual(s.languageItemID, translate)
    }

    func testModesNeedingTheAIWithoutAKey() {
        let s = state(recents: [translate], hasLLMKey: false)
        XCTAssertEqual(s.current?.id, dictate, "a translate mode without a key is not current (as translate-off before)")
        XCTAssertEqual(s.partner?.id, translate)
        XCTAssertEqual(s.partner?.isBlocked, true, "dimmed, a tap explains")
        XCTAssertEqual(s.item(id: polish)?.isBlocked, true)
        XCTAssertEqual(s.item(id: email)?.isBlocked, true)
        XCTAssertEqual(s.item(id: dictate)?.isBlocked, false, "聽寫 follows AI 潤飾 and works without a key")

        let unknown = state(recents: [translate], hasLLMKey: nil)
        XCTAssertEqual(unknown.current?.id, translate, "the keyboard cannot see the keys: nothing is blocked")
        XCTAssertFalse(unknown.menu.contains(where: \.isBlocked))
    }

    func testBaseModeFollowsTheDefault() {
        var modes = DictationModeConfig.builtIns
        for index in modes.indices { modes[index].isDefault = modes[index].id == polish }
        var s = state(modes)
        XCTAssertEqual(s.baseID, polish)
        XCTAssertEqual(s.current?.id, polish)
        XCTAssertTrue(s.isCalm)
        XCTAssertEqual(s.partner?.id, translate)

        // The default is 改寫 (not offered): 聽寫 is the base.
        for index in modes.indices { modes[index].isDefault = modes[index].id == rewrite }
        s = state(modes)
        XCTAssertEqual(s.baseID, dictate)
        XCTAssertEqual(s.current?.id, dictate)
    }

    func testOnlyOneModeLeft() {
        var modes = DictationModeConfig.builtIns
        for index in modes.indices { modes[index].isEnabled = modes[index].id == dictate || modes[index].id == rewrite }
        let s = state(modes)
        XCTAssertEqual(s.current?.id, dictate)
        XCTAssertNil(s.partner)
        XCTAssertFalse(s.showsKey, "nothing to switch to: the key's place stays empty")
    }

    // MARK: The request

    func testRequestCarriesTheModeID() {
        let custom = DictationModeConfig(id: "6F1D2C1A-0000-4000-8000-000000000001", name: "客服", icon: "message",
                                         ai: ModeAI(enabled: .custom(true)),
                                         context: ModeContextFlags(selectedText: true, clipboard: true, appName: true))
        let modes = DictationModeConfig.builtIns + [custom]
        let cases: [(recents: [String], modeID: String, legacy: DictationMode)] = [
            ([], dictate, .dictate),
            ([translate], translate, .translate),
            ([email], email, .dictate),
            ([assistant], assistant, .dictate),
            ([custom.id], custom.id, .dictate),
        ]
        for c in cases {
            let s = state(modes, recents: c.recents)
            let request = KeyboardModes.request(s, selectedText: nil, fieldHint: .chat, id: "r1")
            XCTAssertEqual(request.modeID, c.modeID)
            XCTAssertEqual(request.mode, c.legacy)
            XCTAssertEqual(request.fieldHint, .chat)
            XCTAssertNil(request.selectedText)
            XCTAssertNil(request.clipboardText, "the keyboard never reads the clipboard")
            XCTAssertNil(request.appName)
            // What the app / in-keyboard pipeline runs for it.
            let resolved = ModeResolver.resolve(request, modes: modes, prompts: PromptLibrary.builtIns, defaults: defaults())
            XCTAssertEqual(resolved.modeID, c.modeID)
        }
        // Survives the keyboard ↔ app handoff (JSON in the App Group).
        let sent = KeyboardModes.request(state(modes, recents: [custom.id]), selectedText: nil, fieldHint: .general)
        let received = try? JSONDecoder().decode(DictationRequest.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(received?.modeID, custom.id)
    }

    func testSelectionRewritesWithRewrite() {
        let s = state(recents: [translate])
        let request = KeyboardModes.request(s, selectedText: "明天見", fieldHint: .general)
        XCTAssertEqual(request.mode, .edit)
        XCTAssertEqual(request.modeID, rewrite)
        XCTAssertEqual(request.selectedText, "明天見")
        let resolved = ModeResolver.resolve(request, modes: DictationModeConfig.builtIns, prompts: PromptLibrary.builtIns,
                                            defaults: defaults(polish: .groq))
        XCTAssertEqual(resolved.task, .rewrite)

        // 改寫 disabled: the selection is typed over in the current mode, and not sent anywhere.
        var modes = DictationModeConfig.builtIns
        modes[modes.firstIndex { $0.id == rewrite }!].isEnabled = false
        let plain = state(modes, recents: [translate])
        XCTAssertFalse(plain.rewriteOnSelection)
        let typed = KeyboardModes.request(plain, selectedText: "明天見", fieldHint: .general)
        XCTAssertEqual(typed.modeID, translate)
        XCTAssertNil(typed.selectedText)
    }

    // MARK: Fallback when the store cannot be read

    func testMissingStoreFileIsTheShippedModes() {
        let store = ModeStore(fileURL: url, recents: recents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(state(of: store), state())
        XCTAssertEqual(state(of: store).menu.map(\.id), [dictate, polish, translate, email])
    }

    func testUnreadableStoreFileFallsBackToTheShippedModes() throws {
        try Data("{ not json".utf8).write(to: url)
        let store = ModeStore(fileURL: url, recents: recents)
        XCTAssertEqual(state(of: store), state(), "a corrupt file behaves like no file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "moved aside, not overwritten")

        // A file this version can only partly read: the readable modes are used, the rest are built-ins.
        let json = #"{"version":1,"items":[{"name":"沒有 id"},{"id":"builtin.translate","isEnabled":false}]}"#
        try Data(json.utf8).write(to: url)
        let partial = state(of: ModeStore(fileURL: url, recents: recents))
        XCTAssertEqual(partial.current?.id, dictate)
        XCTAssertFalse(partial.menu.contains { $0.id == translate }, "the readable change (translate off) is kept")
    }

    func testNoModesAtAllMeansTheShippedOnes() {
        // What the keyboard uses before it can read anything (e.g. no App Group without Full Access).
        let empty = KeyboardModes.state(modes: [], prompts: [], defaults: defaults(), recents: ["x"],
                                        keyboardLanguageID: "zz", hasLLMKey: nil)
        XCTAssertEqual(empty.current?.id, dictate)
        XCTAssertEqual(empty.partner?.id, translate)
        XCTAssertEqual(empty.item(id: translate)?.translateLanguageID, "en", "unknown language → English")
    }

    // MARK: Outputs iOS does not have

    func testOutputsOnIOS() {
        XCTAssertEqual(KeyboardModes.delivery(for: .paste), .insert)
        XCTAssertEqual(KeyboardModes.delivery(for: .replaceSelection), .insert)
        XCTAssertEqual(KeyboardModes.delivery(for: .answer), .insert, "no answer panel on iOS: the answer is typed")
        XCTAssertEqual(KeyboardModes.delivery(for: .copyOnly), .copy)

        var modes = DictationModeConfig.builtIns
        modes.append(DictationModeConfig(id: "copy", name: "只複製", ai: ModeAI(enabled: .custom(false)),
                                         output: .copyOnly, autoSend: .returnKey))
        let prompts = PromptLibrary.builtIns
        func delivery(_ recents: [String], selection: String? = nil) -> KeyboardModes.Delivery {
            let request = KeyboardModes.request(state(modes, recents: recents), selectedText: selection, fieldHint: .general)
            return KeyboardModes.delivery(for: request, modes: modes, prompts: prompts, defaults: defaults())
        }
        XCTAssertEqual(delivery([assistant]), .insert)
        XCTAssertEqual(delivery(["copy"]), .copy)
        XCTAssertEqual(delivery([dictate]), .insert)
        XCTAssertEqual(delivery(["copy"], selection: "選取"), .insert, "a selection is rewritten in place")
        XCTAssertEqual(state(modes, recents: [assistant]).current?.output, .answer)
    }
}
