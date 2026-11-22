import XCTest
@testable import ScriberCore
import ScriberShared

/// `PromptLibrary`: shipped prompts, user prompts CRUD, 還原預設, persistence.
final class PromptLibraryTests: XCTestCase {
    private var directory: URL!
    private var url: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberPrompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("prompts.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testShippedPrompts() {
        let library = PromptLibrary(fileURL: url)
        XCTAssertEqual(library.snapshot().map(\.name), ["預設", "Email", "改寫", "翻譯", "助理", "條列重點", "會議紀錄"])
        XCTAssertEqual(library.snapshot().map(\.id), BuiltInPromptID.allCases.map(\.rawValue))
        let kinds = Dictionary(uniqueKeysWithValues: library.snapshot().map { ($0.builtInID!, $0.kind) })
        XCTAssertEqual(kinds[.standard], .dictation)
        XCTAssertEqual(kinds[.email], .dictation)
        XCTAssertEqual(kinds[.bullets], .dictation)
        XCTAssertEqual(kinds[.meeting], .dictation)
        XCTAssertEqual(kinds[.translate], .translate)
        XCTAssertEqual(kinds[.rewrite], .rewrite)
        XCTAssertEqual(kinds[.assistant], .assistant, "助理 is the only prompt that answers")
        XCTAssertTrue(library.snapshot().allSatisfy(\.isPristineBuiltIn))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "reading never writes")
        for prompt in library.snapshot() {
            XCTAssertFalse(ZhTW.containsSimplified(prompt.body.replacingOccurrences(of: "软件、视频、网络、信息、质量、默认、程序、服务器、数据、屏幕、项目", with: "")),
                           "\(prompt.name) is written in Traditional Chinese")
            XCTAssertFalse(prompt.body.contains("臺"), "\(prompt.name) uses 台")
            XCTAssertLessThanOrEqual(prompt.body.count, PromptLibrary.maxBodyLength)
        }
    }

    func testUserPromptCRUDAndPersistence() throws {
        let library = PromptLibrary(fileURL: url)
        let added = try library.add(name: "  客服回覆  ", body: "- 語氣親切。\n\n請整理成客服回覆。")
        XCTAssertEqual(added.name, "客服回覆", "trimmed")
        XCTAssertEqual(added.kind, .dictation, "user prompts are dictation-type unless chosen otherwise")
        XCTAssertFalse(added.isBuiltIn)
        XCTAssertEqual(PromptLibrary(fileURL: url).prompt(id: added.id), added)

        var changed = added
        changed.body = "改過的說明"
        changed.kind = .translate
        try library.update(changed)
        XCTAssertEqual(PromptLibrary(fileURL: url).prompt(id: added.id), changed)

        let copy = try library.duplicate(id: added.id)
        XCTAssertNotEqual(copy.id, added.id)
        XCTAssertEqual(copy.body, changed.body)
        XCTAssertEqual(library.snapshot().suffix(2).map(\.id), [added.id, copy.id], "user prompts after shipped ones, in order")

        try library.delete(id: added.id)
        XCTAssertNil(library.prompt(id: added.id))
        XCTAssertThrowsError(try library.delete(id: added.id)) { XCTAssertEqual($0 as? PromptLibraryError, .notFound) }
        XCTAssertThrowsError(try library.update(changed)) { XCTAssertEqual($0 as? PromptLibraryError, .notFound) }
        XCTAssertThrowsError(try library.add(name: "   ", body: "x")) { XCTAssertEqual($0 as? PromptLibraryError, .emptyName) }
        XCTAssertThrowsError(try library.add(name: "長", body: String(repeating: "字", count: PromptLibrary.maxBodyLength + 1))) {
            XCTAssertEqual($0 as? PromptLibraryError, .bodyTooLong)
        }
    }

    func testShippedPromptEditAndRestore() throws {
        let library = PromptLibrary(fileURL: url)
        var email = try XCTUnwrap(library.prompt(id: BuiltInPromptID.email.rawValue))
        email.body = "只要分段就好。"
        email.kind = .assistant // a shipped prompt's kind cannot change
        try library.update(email)
        let edited = try XCTUnwrap(PromptLibrary(fileURL: url).prompt(id: email.id))
        XCTAssertEqual(edited.body, "只要分段就好。")
        XCTAssertEqual(edited.kind, .dictation)
        XCTAssertTrue(edited.isModified)
        XCTAssertFalse(edited.isPristineBuiltIn)

        XCTAssertThrowsError(try library.delete(id: email.id)) {
            XCTAssertEqual($0 as? PromptLibraryError, .builtInCannotBeDeleted)
        }
        try library.restoreBuiltIn(id: email.id)
        XCTAssertEqual(library.prompt(id: email.id), PromptLibrary.builtIn(.email))
        XCTAssertTrue(try XCTUnwrap(library.prompt(id: email.id)).isPristineBuiltIn)

        // Saving the shipped text again stores nothing: later app updates to it still arrive.
        try library.update(PromptLibrary.builtIn(.translate))
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual((stored?["items"] as? [Any])?.count ?? 0, 0)

        let mine = try library.add(name: "我的", body: "x")
        XCTAssertThrowsError(try library.restoreBuiltIn(id: mine.id)) { XCTAssertEqual($0 as? PromptLibraryError, .notBuiltIn) }
    }

    func testCorruptFileFallsBackToShippedPrompts() throws {
        try Data("garbage".utf8).write(to: url)
        let library = PromptLibrary(fileURL: url)
        XCTAssertEqual(library.snapshot(), PromptLibrary.builtIns)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("prompts.corrupt-") })
    }

    func testTolerantDecoding() throws {
        let json = """
        {"version": 1, "items": [
          {"id": "u1", "name": "未來的", "kind": "summarizeV9", "body": "x", "extra": true},
          {"id": "u2", "name": "沒有內文"},
          {"id": "builtin.prompt.meeting", "body": "改過"},
          {"nope": 1}
        ]}
        """
        try Data(json.utf8).write(to: url)
        let library = PromptLibrary(fileURL: url)
        XCTAssertEqual(library.prompt(id: "u1")?.kind, .dictation, "unknown kind → dictation (never answers)")
        XCTAssertNil(library.prompt(id: "u2"), "a user prompt without text is skipped")
        XCTAssertEqual(library.prompt(id: BuiltInPromptID.meeting.rawValue)?.body, "改過")
        XCTAssertEqual(library.prompt(id: BuiltInPromptID.meeting.rawValue)?.name, "會議紀錄")
        XCTAssertEqual(library.snapshot().count, 8)
    }
}
