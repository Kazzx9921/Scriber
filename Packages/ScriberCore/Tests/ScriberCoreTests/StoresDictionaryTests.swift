import XCTest
@testable import ScriberCore
import ScriberShared

final class StoresDictionaryTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("dictionary.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberStoresTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func drainMainQueue() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: - Persistence

    func testAddUpdateRemovePersist() {
        let store = DictionaryStore(fileURL: fileURL)
        XCTAssertTrue(store.entries.isEmpty)
        let claude = DictionaryEntry(term: "Claude Code", soundsLike: ["cloud code"])
        let place = DictionaryEntry(term: "鹿野", soundsLike: ["路野"])
        store.add(claude)
        store.add(place)
        XCTAssertEqual(store.entries, [claude, place])
        XCTAssertEqual(store.snapshot(), [claude, place])

        var edited = claude
        edited.soundsLike.append("克勞德扣")
        store.update(edited)
        XCTAssertEqual(store.entries.first, edited)
        // Adding an entry with an existing id replaces it instead of duplicating.
        store.add(edited)
        XCTAssertEqual(store.entries.count, 2)
        // Updating a removed entry does not bring it back.
        store.remove(ids: [place.id])
        store.update(place)
        XCTAssertEqual(store.entries, [edited])

        let reloaded = DictionaryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries, [edited])
        XCTAssertEqual(reloaded.snapshot(), [edited])
    }

    func testMissingAndCorruptFiles() throws {
        XCTAssertTrue(DictionaryStore(fileURL: directory.appendingPathComponent("nope/missing.json")).entries.isEmpty)

        try Data("{ not json".utf8).write(to: fileURL)
        let store = DictionaryStore(fileURL: fileURL)
        XCTAssertTrue(store.entries.isEmpty)
        // The unreadable file is kept aside rather than overwritten.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("dictionary.corrupt-") }, "\(names)")
        store.add(DictionaryEntry(term: "Supabase"))
        XCTAssertEqual(DictionaryStore(fileURL: fileURL).entries.map(\.term), ["Supabase"])
    }

    func testOneBadEntryDoesNotLoseTheRest() throws {
        let good = DictionaryEntry(term: "GitHub", soundsLike: ["git hub"])
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let json = #"{"version":1,"items":[{"term":"missing id"},\#(goodJSON),42]}"#
        try Data(json.utf8).write(to: fileURL)
        XCTAssertEqual(DictionaryStore(fileURL: fileURL).entries, [good])

        // A bare array (hand-made import) is accepted too.
        try Data("[\(goodJSON)]".utf8).write(to: fileURL)
        XCTAssertEqual(DictionaryStore(fileURL: fileURL).entries, [good])
    }

    func testBackgroundMutationsAreSafe() {
        let store = DictionaryStore(fileURL: fileURL)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            store.add(DictionaryEntry(term: "term \(i)"))
            _ = store.snapshot()
            _ = store.applyReplacements(to: "term 1 和 term 2")
        }
        XCTAssertEqual(store.snapshot().count, 200)
        drainMainQueue()
        XCTAssertEqual(store.entries.count, 200)
        XCTAssertEqual(Set(DictionaryStore(fileURL: fileURL).entries.map(\.term)).count, 200)
    }

    // MARK: - Replacements

    private func makeStore(_ entries: [DictionaryEntry]) -> DictionaryStore {
        let store = DictionaryStore(fileURL: directory.appendingPathComponent("\(UUID().uuidString).json"))
        for entry in entries { store.add(entry) }
        return store
    }

    private func replace(_ text: String, _ entries: [DictionaryEntry]) -> String {
        makeStore(entries).applyReplacements(to: text)
    }

    func testLatinReplacementIsCaseInsensitive() {
        let entries = [DictionaryEntry(term: "Claude Code", soundsLike: ["cloud code"])]
        XCTAssertEqual(replace("我在用 cloud code 寫程式", entries), "我在用 Claude Code 寫程式")
        XCTAssertEqual(replace("我在用Cloud Code寫程式", entries), "我在用Claude Code寫程式")
        XCTAssertEqual(replace("CLOUD CODE!", entries), "Claude Code!")
        XCTAssertEqual(replace("cloud  code", entries), "Claude Code")
        XCTAssertEqual(replace("😀cloud code😀", entries), "😀Claude Code😀")
    }

    func testLatinNeedsWordBoundaries() {
        let entries = [DictionaryEntry(term: "PR", soundsLike: ["pr"]), DictionaryEntry(term: "iOS", soundsLike: ["ios"])]
        XCTAssertEqual(replace("幫我開一個pr", entries), "幫我開一個PR")
        XCTAssertEqual(replace("我的 pr，ios 也要", entries), "我的 PR，iOS 也要")
        XCTAssertEqual(replace("寫 prompt 跟 April 的 bios 設定", entries), "寫 prompt 跟 April 的 bios 設定")
        XCTAssertEqual(replace("ios18 和 my_pr", entries), "ios18 和 my_pr")
        XCTAssertEqual(replace("pr-123", entries), "PR-123")
    }

    func testCJKIsPlainSubstringAndScriptInsensitive() {
        let entries = [DictionaryEntry(term: "鹿野", soundsLike: ["路野"]),
                       DictionaryEntry(term: "Claude", soundsLike: ["克勞德"])]
        XCTAssertEqual(replace("我們去路野玩", entries), "我們去鹿野玩")
        XCTAssertEqual(replace("克勞德很好用", entries), "Claude很好用")
        // Whisper often returns Simplified before the zh-TW step runs.
        XCTAssertEqual(replace("克劳德很好用", entries), "Claude很好用")
    }

    func testLongestMatchFirstAndNoCascading() {
        let entries = [DictionaryEntry(term: "Claude", soundsLike: ["克勞德"]),
                       DictionaryEntry(term: "Claude Code", soundsLike: ["克勞德扣", "克勞德 code"]),
                       DictionaryEntry(term: "B", soundsLike: ["a"]),
                       DictionaryEntry(term: "C", soundsLike: ["b"])]
        XCTAssertEqual(replace("克勞德扣跟克勞德", entries), "Claude Code跟Claude")
        XCTAssertEqual(replace("用克勞德code寫", entries), "用Claude Code寫")
        XCTAssertEqual(replace("用克勞德 code 寫", entries), "用Claude Code 寫")
        XCTAssertEqual(replace("a b", entries), "B C")
    }

    func testReplacementEdgeCases() {
        let entries = [DictionaryEntry(term: "", soundsLike: ["x"]),
                       DictionaryEntry(term: "Supabase", soundsLike: ["", "  ", "supabase"]),
                       DictionaryEntry(term: "鹿野")]
        XCTAssertEqual(replace("x 和 supabase", entries), "x 和 Supabase")
        XCTAssertEqual(replace("", entries), "")
        XCTAssertEqual(replace("Supabase", entries), "Supabase")
        let once = replace("supa base 跟 supabase", entries)
        XCTAssertEqual(replace(once, entries), once)
        XCTAssertEqual(replace("沒有字典", []), "沒有字典")
    }

    // MARK: - Built-in suggestions

    func testBuiltInEntries() {
        let builtIn = DictionaryStore.builtInEntries
        XCTAssertGreaterThanOrEqual(builtIn.count, 30)
        XCTAssertEqual(Set(builtIn.map { $0.term.lowercased() }).count, builtIn.count, "duplicate terms")
        for entry in builtIn {
            XCTAssertFalse(entry.term.isEmpty)
            XCTAssertFalse(entry.soundsLike.isEmpty, entry.term)
            XCTAssertFalse(ZhTW.containsSimplified(entry.term + entry.soundsLike.joined()), entry.term)
        }
        for term in ["Claude Code", "Supabase", "Railway", "GitHub", "deploy", "PR", "prompt", "n8n", "Figma", "iOS"] {
            XCTAssertTrue(builtIn.contains { $0.term == term }, term)
        }
        // Offered, never inserted.
        XCTAssertTrue(DictionaryStore(fileURL: fileURL).entries.isEmpty)
    }

    func testBuiltInEntriesFixTypicalTranscripts() {
        let builtIn = DictionaryStore.builtInEntries
        XCTAssertEqual(replace("我用cloud code把專案 de ploy 到 rail way，再開一個 pr", builtIn),
                       "我用Claude Code把專案 deploy 到 Railway，再開一個 PR")
        XCTAssertEqual(replace("用 n 8 n 串 supa base 跟 github，ios 跟 figma 也行", builtIn),
                       "用 n8n 串 Supabase 跟 GitHub，iOS 跟 Figma 也行")
        XCTAssertEqual(replace("克劳德扣好用", builtIn), "Claude Code好用")
    }

    func testBuiltInEntriesLeaveOrdinaryTextAlone() {
        let builtIn = DictionaryStore.builtInEntries
        let untouched = [
            "I said the build was rapid and the print queue is empty in April.",
            "We need to maintain the bios settings and the prompts list.",
            "這份文件很重要，我們明天在台北見面。",
            "他是我們公司的幹部，後來去了雲端部門。",
        ] + ZhTWGoldenData.s2twp.map(\.output)
        let store = makeStore(builtIn)
        for text in untouched {
            XCTAssertEqual(store.applyReplacements(to: text), text)
        }
    }
}
