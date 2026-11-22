import XCTest
@testable import ScriberCore
import ScriberShared

/// `ModeStore`: persistence, corruption handling, invariants (one default, never zero enabled).
final class ModeStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var recents: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberModeStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("modes.json")
        suiteName = "ScriberModeStoreTests-\(UUID().uuidString)"
        recents = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        recents.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> ModeStore { ModeStore(fileURL: url, recents: recents) }

    private func assertInvariants(_ modes: [DictationModeConfig], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(modes.filter(\.isDefault).count, 1, "exactly one default", file: file, line: line)
        XCTAssertTrue(modes.first(where: \.isDefault)?.isEnabled == true, "the default is enabled", file: file, line: line)
        XCTAssertFalse(modes.filter(\.isEnabled).isEmpty, "never zero enabled", file: file, line: line)
        XCTAssertEqual(Set(modes.map(\.id)).count, modes.count, "unique ids", file: file, line: line)
        for builtIn in BuiltInModeID.allCases {
            XCTAssertTrue(modes.contains { $0.id == builtIn.rawValue }, "\(builtIn) present", file: file, line: line)
        }
    }

    // MARK: Fresh store

    func testFreshStoreIsTheShippedModesAndWritesNothing() {
        let s = store()
        XCTAssertEqual(s.snapshot().map(\.id), BuiltInModeID.allCases.map(\.rawValue))
        XCTAssertEqual(s.snapshot().map(\.name), ["聽寫", "潤飾", "翻譯", "改寫", "Email", "助理"])
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.dictate.rawValue)
        XCTAssertTrue(s.snapshot().allSatisfy(\.isEnabled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "reading never writes")
        assertInvariants(s.snapshot())
        XCTAssertEqual(s.modes, s.snapshot(), "observable copy is filled at init")
    }

    func testShippedModesMatchThePRD() {
        let modes = Dictionary(uniqueKeysWithValues: DictationModeConfig.builtIns.map { ($0.builtInID!, $0) })
        XCTAssertEqual(modes[.dictate]?.ai.enabled, .followDefault, "聽寫 follows the global AI 潤飾 switch")
        XCTAssertEqual(modes[.polish]?.ai.enabled, .custom(true))
        XCTAssertEqual(modes[.rewrite]?.output, .replaceSelection)
        XCTAssertEqual(modes[.rewrite]?.context.selectedText, true)
        XCTAssertEqual(modes[.assistant]?.output, .answer)
        XCTAssertEqual(modes[.email]?.trigger.appBundleIDs, ["com.apple.mail"])
        XCTAssertEqual(modes[.translate]?.ai.promptID, BuiltInPromptID.translate.rawValue)
        for mode in modes.values {
            XCTAssertEqual(mode.recognition, ModeRecognition(), "\(mode.name): engine/language/realtime follow default")
            XCTAssertEqual(mode.textFormat, ModeTextFormat(), "\(mode.name): text format follows default")
            XCTAssertEqual(mode.ai.provider, .followDefault)
            XCTAssertEqual(mode.autoSend, .none, "auto-send defaults to off (PRD §7.5)")
            XCTAssertFalse(mode.context.clipboard || mode.context.appName, "context off by default (PRD §7.6)")
        }
    }

    // MARK: Round trip

    func testRoundTripThroughTheFile() throws {
        let s = store()
        var mine = DictationModeConfig(name: "寫程式", icon: "chevron.left.forwardslash.chevron.right")
        mine.recognition = ModeRecognition(engine: .custom(.groqWhisperTurbo), language: .custom("en"), realtime: .custom(false))
        mine.textFormat = ModeTextFormat(forceTraditional: .custom(false), punctuationRule: .custom(.keep), punctuationLimit: .custom(0))
        mine.ai = ModeAI(enabled: .custom(true), provider: .custom(.anthropic), model: "claude-haiku-5-5",
                         promptID: BuiltInPromptID.bullets.rawValue, translateLanguageID: .custom("ja"))
        mine.context = ModeContextFlags(selectedText: true, clipboard: true, appName: true)
        mine.trigger = ModeTrigger(hotkey: ModeHotkey(kind: .combination, modifiers: ["control", "option"], keyCode: 2, keyLabel: "D"),
                                   appBundleIDs: ["com.microsoft.VSCode"])
        mine.output = .copyOnly
        mine.autoSend = .commandReturn
        let added = s.add(mine)
        XCTAssertEqual(added.id, mine.id)

        let reopened = store()
        XCTAssertEqual(reopened.mode(id: mine.id), added)
        XCTAssertEqual(reopened.snapshot().count, 7)
        XCTAssertEqual(reopened.snapshot().last?.id, mine.id)

        // The JSON is the documented envelope with a version on every mode.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 7)
        XCTAssertTrue(items.allSatisfy { ($0["version"] as? Int) == DictationModeConfig.currentVersion })
        let stored = try XCTUnwrap(items.first { ($0["id"] as? String) == mine.id })
        XCTAssertTrue((stored["recognition"] as? [String: Any])?["engine"] as? String == "groqWhisperTurbo")
        let dictate = try XCTUnwrap(items.first { ($0["id"] as? String) == BuiltInModeID.dictate.rawValue })
        XCTAssertTrue((dictate["recognition"] as? [String: Any])?["engine"] is NSNull, "follow default is null")
    }

    func testUpdateReorderAndAnotherInstanceSeesIt() throws {
        let app = store()
        let keyboard = store()
        var email = try XCTUnwrap(app.mode(id: BuiltInModeID.email.rawValue))
        email.name = "寫信"
        email.textFormat.punctuationRule = .custom(.keep)
        try app.update(email)
        XCTAssertEqual(keyboard.mode(id: email.id)?.name, "寫信", "the other process reads the new file")

        let ids = app.snapshot().map(\.id)
        keyboard.reorder(ids: [BuiltInModeID.assistant.rawValue, BuiltInModeID.translate.rawValue])
        XCTAssertEqual(Array(app.snapshot().map(\.id).prefix(2)), [BuiltInModeID.assistant.rawValue, BuiltInModeID.translate.rawValue])
        XCTAssertEqual(Set(app.snapshot().map(\.id)), Set(ids), "reorder never loses a mode")

        app.move(fromOffsets: IndexSet(integer: 0), toOffset: 6)
        XCTAssertEqual(app.snapshot().last?.id, BuiltInModeID.assistant.rawValue)
        XCTAssertEqual(app.snapshot().first?.id, BuiltInModeID.translate.rawValue)
        assertInvariants(keyboard.snapshot())
    }

    func testAddNeverReusesAnIDAndCanBecomeDefault() {
        let s = store()
        var clash = DictationModeConfig(id: BuiltInModeID.dictate.rawValue, name: "冒充")
        clash.isDefault = true
        clash.isEnabled = false
        let added = s.add(clash)
        XCTAssertNotEqual(added.id, BuiltInModeID.dictate.rawValue)
        XCTAssertEqual(s.mode(id: BuiltInModeID.dictate.rawValue)?.name, "聽寫", "the shipped mode is untouched")
        XCTAssertEqual(s.defaultMode.id, added.id, "isDefault on add makes it the default")
        XCTAssertTrue(s.defaultMode.isEnabled, "the default is enabled")
        let again = s.add(DictationModeConfig(id: added.id, name: "同 id"))
        XCTAssertNotEqual(again.id, added.id)
        assertInvariants(s.snapshot())
    }

    // MARK: Invariants

    func testCannotDisableTheLastEnabledMode() throws {
        let s = store()
        for id in BuiltInModeID.allCases.dropLast().map(\.rawValue) { try s.setEnabled(false, id: id) }
        assertInvariants(s.snapshot())
        XCTAssertEqual(s.enabledModes.map(\.id), [BuiltInModeID.assistant.rawValue])
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.assistant.rawValue, "the default moved to the only enabled mode")
        XCTAssertThrowsError(try s.setEnabled(false, id: BuiltInModeID.assistant.rawValue)) {
            XCTAssertEqual($0 as? ModeStoreError, .lastEnabledMode)
        }
        XCTAssertEqual(store().enabledModes.count, 1, "the refused change was not written")
    }

    func testDisablingTheDefaultMovesTheDefault() throws {
        let s = store()
        try s.setDefault(id: BuiltInModeID.email.rawValue)
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.email.rawValue)
        try s.setEnabled(false, id: BuiltInModeID.email.rawValue)
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.dictate.rawValue, "back to 聽寫")
        try s.setEnabled(false, id: BuiltInModeID.dictate.rawValue)
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.polish.rawValue, "then the first enabled mode")
        assertInvariants(s.snapshot())
    }

    func testSetDefaultEnablesTheModeAndKeepsExactlyOne() throws {
        let s = store()
        try s.setEnabled(false, id: BuiltInModeID.translate.rawValue)
        try s.setDefault(id: BuiltInModeID.translate.rawValue)
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.translate.rawValue)
        XCTAssertTrue(s.defaultMode.isEnabled)
        // Clearing isDefault on the default through update does not leave zero defaults.
        var translate = s.defaultMode
        translate.isDefault = false
        try s.update(translate)
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.translate.rawValue)
        // Setting it on another mode through update moves it.
        var email = try XCTUnwrap(s.mode(id: BuiltInModeID.email.rawValue))
        email.isDefault = true
        try s.update(email)
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.email.rawValue)
        assertInvariants(s.snapshot())
        XCTAssertThrowsError(try s.setDefault(id: "nope")) { XCTAssertEqual($0 as? ModeStoreError, .notFound) }
    }

    func testDeleteAndDuplicate() throws {
        let s = store()
        XCTAssertThrowsError(try s.delete(id: BuiltInModeID.translate.rawValue)) {
            XCTAssertEqual($0 as? ModeStoreError, .builtInCannotBeDeleted)
        }
        let copy = try s.duplicate(id: BuiltInModeID.email.rawValue)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertFalse(copy.isDefault)
        XCTAssertEqual(copy.ai, s.mode(id: BuiltInModeID.email.rawValue)?.ai)
        let ids = s.snapshot().map(\.id)
        XCTAssertEqual(ids.firstIndex(of: copy.id), ids.firstIndex(of: BuiltInModeID.email.rawValue).map { $0 + 1 })
        try s.setDefault(id: copy.id)
        try s.delete(id: copy.id)
        XCTAssertNil(s.mode(id: copy.id))
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.dictate.rawValue, "deleting the default moves it")
        XCTAssertThrowsError(try s.delete(id: copy.id)) { XCTAssertEqual($0 as? ModeStoreError, .notFound) }
        assertInvariants(s.snapshot())
    }

    func testDeletingTheOnlyEnabledModeIsRefused() throws {
        let s = store()
        let mine = s.add(DictationModeConfig(name: "我的"))
        for id in BuiltInModeID.allCases.map(\.rawValue) { try s.setEnabled(false, id: id) }
        XCTAssertEqual(s.enabledModes.map(\.id), [mine.id])
        XCTAssertThrowsError(try s.delete(id: mine.id)) { XCTAssertEqual($0 as? ModeStoreError, .lastEnabledMode) }
    }

    func testRestoreDefaultKeepsPlaceEnabledAndDefault() throws {
        let s = store()
        var translate = try XCTUnwrap(s.mode(id: BuiltInModeID.translate.rawValue))
        translate.name = "Translate"
        translate.ai.provider = .custom(.anthropic)
        translate.output = .copyOnly
        try s.update(translate)
        try s.setDefault(id: translate.id)
        s.reorder(ids: [translate.id])
        try s.restoreDefault(id: translate.id)
        let restored = try XCTUnwrap(s.mode(id: translate.id))
        var expected = DictationModeConfig.builtIn(.translate)
        expected.isDefault = true
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(s.snapshot().first?.id, translate.id, "position kept")
        let mine = s.add(DictationModeConfig(name: "我的"))
        XCTAssertThrowsError(try s.restoreDefault(id: mine.id)) { XCTAssertEqual($0 as? ModeStoreError, .notBuiltIn) }
    }

    // MARK: Damaged files

    func testCorruptFileFallsBackToShippedModesAndIsKeptAside() throws {
        try Data("{ not json".utf8).write(to: url)
        let s = store()
        XCTAssertEqual(s.snapshot().map(\.id), BuiltInModeID.allCases.map(\.rawValue))
        assertInvariants(s.snapshot())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("modes.corrupt-") }, "\(files)")
        // Still fully usable.
        try s.setDefault(id: BuiltInModeID.polish.rawValue)
        XCTAssertEqual(store().defaultMode.id, BuiltInModeID.polish.rawValue)
    }

    func testTolerantDecodingOfUnknownAndMissingFields() throws {
        let json = """
        {"version": 1, "items": [
          {"id": "builtin.dictate", "version": 7, "name": "聽寫", "futureField": {"x": 1},
           "recognition": {"engine": "someFutureEngine", "language": "en", "realtime": null},
           "textFormat": {"punctuationRule": "keep", "punctuationLimit": "many"},
           "ai": {"enabled": true, "provider": "openaiCompatible", "promptID": "builtin.prompt.email"},
           "output": "speakAloud", "autoSend": "tripleClick", "isDefault": true},
          {"id": "user-1", "name": "最小"},
          {"name": "沒有 id"},
          "not an object",
          {"id": "user-1", "name": "重複的 id"}
        ]}
        """
        try Data(json.utf8).write(to: url)
        let s = store()
        let modes = s.snapshot()
        assertInvariants(modes)
        let dictate = try XCTUnwrap(s.mode(id: BuiltInModeID.dictate.rawValue))
        XCTAssertEqual(dictate.version, 7, "a newer version is kept as is")
        XCTAssertEqual(dictate.recognition.engine, .followDefault, "unknown engine → follow default")
        XCTAssertEqual(dictate.recognition.language, .custom("en"))
        XCTAssertEqual(dictate.textFormat.punctuationRule, .custom(.keep))
        XCTAssertEqual(dictate.textFormat.punctuationLimit, .followDefault, "wrong type → follow default")
        XCTAssertEqual(dictate.ai.enabled, .custom(true))
        XCTAssertEqual(dictate.ai.provider, .followDefault, "unknown provider → follow default")
        XCTAssertEqual(dictate.output, .paste, "unknown output → paste")
        XCTAssertEqual(dictate.autoSend, .none, "unknown auto-send → none")
        XCTAssertEqual(s.defaultMode.id, dictate.id)

        let minimal = try XCTUnwrap(s.mode(id: "user-1"))
        XCTAssertEqual(minimal.name, "最小", "first copy of an id wins")
        XCTAssertTrue(minimal.isEnabled)
        XCTAssertEqual(minimal.ai, ModeAI())
        XCTAssertEqual(minimal.output, .paste)
        XCTAssertEqual(modes.count, 7, "the missing shipped modes are added back")

        // The file had modes this version cannot read: a copy is kept before a write drops them.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("modes.unreadable-") }, "\(files)")
    }

    func testAllDisabledOrNoDefaultOnDiskIsRepaired() throws {
        var modes = DictationModeConfig.builtIns
        for index in modes.indices { modes[index].isEnabled = false; modes[index].isDefault = true }
        struct Envelope: Encodable { var version = 1; var items: [DictationModeConfig] }
        try JSONEncoder().encode(Envelope(items: modes)).write(to: url)
        let s = store()
        assertInvariants(s.snapshot())
        XCTAssertEqual(s.enabledModes.map(\.id), [BuiltInModeID.dictate.rawValue])
        XCTAssertEqual(s.defaultMode.id, BuiltInModeID.dictate.rawValue)
    }

    // MARK: Recently used (iOS mode key)

    func testRecentModesForTheModeKey() throws {
        let s = store()
        XCTAssertEqual(s.recentModeIDs(limit: 2), [BuiltInModeID.dictate.rawValue, BuiltInModeID.polish.rawValue],
                       "nothing used yet: the default, then list order")
        s.noteUsed(id: BuiltInModeID.translate.rawValue)
        XCTAssertEqual(s.recentModeIDs(limit: 2), [BuiltInModeID.translate.rawValue, BuiltInModeID.dictate.rawValue])
        s.noteUsed(id: BuiltInModeID.email.rawValue)
        s.noteUsed(id: BuiltInModeID.translate.rawValue)
        XCTAssertEqual(s.recentModeIDs(limit: 2), [BuiltInModeID.translate.rawValue, BuiltInModeID.email.rawValue])
        try s.setEnabled(false, id: BuiltInModeID.email.rawValue)
        XCTAssertEqual(s.recentModeIDs(limit: 2), [BuiltInModeID.translate.rawValue, BuiltInModeID.dictate.rawValue],
                       "disabled modes are skipped")
        for _ in 0..<10 { s.noteUsed(id: UUID().uuidString) }
        XCTAssertLessThanOrEqual(recents.stringArray(forKey: ModeStore.recentsKey)?.count ?? 0, ModeStore.recentCapacity)
    }

    // MARK: Legacy request mapping

    func testLegacyRequestEnumMapsToBuiltInModes() throws {
        let s = store()
        let modes = s.snapshot()
        XCTAssertEqual(ModeResolver.mode(for: DictationRequest(mode: .translate), in: modes).id, BuiltInModeID.translate.rawValue)
        XCTAssertEqual(ModeResolver.mode(for: DictationRequest(mode: .edit), in: modes).id, BuiltInModeID.rewrite.rawValue)
        XCTAssertEqual(ModeResolver.mode(for: DictationRequest(mode: .dictate), in: modes).id, BuiltInModeID.dictate.rawValue)
        try s.setDefault(id: BuiltInModeID.email.rawValue)
        XCTAssertEqual(ModeResolver.mode(for: DictationRequest(), in: s.snapshot()).id, BuiltInModeID.email.rawValue,
                       ".dictate means the default mode")
        XCTAssertEqual(ModeResolver.mode(for: DictationRequest(mode: .translate, modeID: BuiltInModeID.assistant.rawValue),
                                         in: s.snapshot()).id, BuiltInModeID.assistant.rawValue, "modeID wins")
        XCTAssertEqual(ModeResolver.mode(for: DictationRequest(mode: .translate, modeID: "deleted"), in: s.snapshot()).id,
                       BuiltInModeID.translate.rawValue, "unknown modeID → the legacy enum")
    }

    func testOldRequestPayloadsStillDecode() throws {
        let old = #"{"id":"r1","mode":"edit","selectedText":"原文","fieldHint":"chat"}"#
        let request = try JSONDecoder().decode(DictationRequest.self, from: Data(old.utf8))
        XCTAssertEqual(request, DictationRequest(id: "r1", mode: .edit, selectedText: "原文", fieldHint: .chat))
        XCTAssertNil(request.modeID)
        let new = DictationRequest(id: "r2", modeID: BuiltInModeID.email.rawValue, clipboardText: "c", appName: "Mail")
        XCTAssertEqual(try JSONDecoder().decode(DictationRequest.self, from: JSONEncoder().encode(new)), new)
    }
}
