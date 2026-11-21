import XCTest
@testable import ScriberCore
import ScriberShared

/// The app and the keyboard extension both write history.json / dictionary.json in the App Group.
/// Two store instances on the same file stand in for the two processes: each has its own memory
/// and its own lock file descriptor, and `flock` locks contend between descriptors exactly as
/// they do between processes.
final class StoresMultiProcessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberMultiProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func item(_ text: String, secondsAgo: TimeInterval = 0) -> HistoryItem {
        HistoryItem(date: Date(timeIntervalSinceNow: -secondsAgo), mode: .dictate, rawTranscript: text,
                    finalText: text, sttProvider: .groqWhisperTurbo, polishProvider: .off, totalMillis: 1)
    }

    func testTwoWritersDoNotDropEachOthersItems() {
        let url = directory.appendingPathComponent("history.json")
        let app = HistoryStore(fileURL: url)
        let keyboard = HistoryStore(fileURL: url)
        app.add(item("app-1", secondsAgo: 30))
        keyboard.add(item("kb-1", secondsAgo: 20))   // keyboard had an empty, stale copy
        app.add(item("app-2", secondsAgo: 10))       // app's copy is stale too
        let expected = ["app-2", "kb-1", "app-1"]
        XCTAssertEqual(HistoryStore(fileURL: url).snapshot().map(\.finalText), expected)
        XCTAssertEqual(app.snapshot().map(\.finalText), expected)
        XCTAssertEqual(keyboard.snapshot().map(\.finalText), expected)
        XCTAssertEqual(app.items.map(\.finalText), expected, "the writer's own observable copy is current")
    }

    func testConcurrentWritersFromTwoInstancesAndManyThreads() {
        let url = directory.appendingPathComponent("list.json")
        let a = PersistentList<String>(fileURL: url)
        let b = PersistentList<String>(fileURL: url)
        let group = DispatchGroup()
        for (name, list) in [("a", a), ("b", b)] {
            for thread in 0..<4 {
                DispatchQueue.global().async(group: group) {
                    for i in 0..<40 { list.mutate { $0.append("\(name)-\(thread)-\(i)") } }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        let fresh = PersistentList<String>(fileURL: url).read()
        XCTAssertEqual(fresh.count, 2 * 4 * 40)
        XCTAssertEqual(Set(fresh).count, fresh.count)
        XCTAssertEqual(Set(a.read()), Set(fresh))
        XCTAssertEqual(Set(b.read()), Set(fresh))
    }

    func testReaderSeesAnotherWritersChangesWithoutMutating() {
        let url = directory.appendingPathComponent("dictionary.json")
        let app = DictionaryStore(fileURL: url)
        let keyboard = DictionaryStore(fileURL: url)
        app.add(DictionaryEntry(term: "Claude Code", soundsLike: ["cloud code"]))
        XCTAssertEqual(keyboard.snapshot().map(\.term), ["Claude Code"])
        XCTAssertEqual(keyboard.applyReplacements(to: "用 cloud code 寫"), "用 Claude Code 寫")
    }

    func testOtherProcessWriteRefreshesObservableCopy() {
        let url = directory.appendingPathComponent("history.json")
        let app = HistoryStore(fileURL: url)
        let keyboard = HistoryStore(fileURL: url)
        keyboard.add(item("from-keyboard"))
        // Darwin notification → main queue → app.items refreshed.
        let deadline = Date().addingTimeInterval(3)
        while app.items.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(app.items.map(\.finalText), ["from-keyboard"])
        app.reload()
        XCTAssertEqual(app.items.count, 1)
    }

    func testLockIsExclusiveBetweenDescriptors() {
        let lockURL = directory.appendingPathComponent(".x.lock")
        let first = CrossProcessFileLock(url: lockURL)
        XCTAssertTrue(first.isLocked)
        let started = Date()
        let second = CrossProcessFileLock(url: lockURL, timeout: 0.2)
        XCTAssertFalse(second.isLocked, "held elsewhere: gives up after the timeout")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.19)
        first.unlock()
        let third = CrossProcessFileLock(url: lockURL, timeout: 0.2)
        XCTAssertTrue(third.isLocked)
        third.unlock()
    }

    func testChangeNotificationNameIsStableAcrossInstances() {
        let url = directory.appendingPathComponent("history.json")
        XCTAssertEqual(PersistentList<String>(fileURL: url).changeNotificationName,
                       PersistentList<String>(fileURL: url).changeNotificationName)
        XCTAssertEqual(PersistentList<String>.stableHash("abc"), "e71fa2190541574b") // FNV-1a 64
    }
}
