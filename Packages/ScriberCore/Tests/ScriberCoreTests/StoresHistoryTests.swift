import XCTest
@testable import ScriberCore
import ScriberShared

final class StoresHistoryTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriberHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func item(_ text: String, secondsAgo: TimeInterval = 0) -> HistoryItem {
        HistoryItem(date: Date(timeIntervalSinceNow: -secondsAgo), mode: .dictate, rawTranscript: "raw " + text,
                    finalText: text, sttProvider: .elevenLabsScribe, polishProvider: .groq, totalMillis: 900)
    }

    private func drainMainQueue() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testNewestFirstAndPersisted() {
        let store = HistoryStore(fileURL: fileURL)
        let a = item("一", secondsAgo: 30), b = item("二", secondsAgo: 20), c = item("三", secondsAgo: 10)
        store.add(a)
        store.add(c)
        store.add(b) // older than c: goes after it
        XCTAssertEqual(store.items.map(\.finalText), ["三", "二", "一"])

        store.remove(ids: [b.id])
        XCTAssertEqual(store.items.map(\.finalText), ["三", "一"])
        let reloaded = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.items, [c, a]) // dates round-trip exactly
        reloaded.clear()
        XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertTrue(HistoryStore(fileURL: fileURL).items.isEmpty)
    }

    func testCapacity() {
        let store = HistoryStore(fileURL: fileURL)
        let base = Date()
        for i in 0..<250 {
            store.add(HistoryItem(date: base.addingTimeInterval(TimeInterval(i)), mode: .dictate, rawTranscript: "\(i)",
                                  finalText: "\(i)", sttProvider: .groqWhisperTurbo, polishProvider: .off, totalMillis: i))
        }
        XCTAssertEqual(store.items.count, HistoryStore.capacity)
        XCTAssertEqual(store.items.first?.finalText, "249")
        XCTAssertEqual(store.items.last?.finalText, "50")
        XCTAssertEqual(HistoryStore(fileURL: fileURL).items.count, 200)
    }

    func testSameIDReplaces() {
        let store = HistoryStore(fileURL: fileURL)
        var first = item("原本")
        store.add(first)
        first.finalText = "修改後"
        store.add(first)
        XCTAssertEqual(store.items.map(\.finalText), ["修改後"])
    }

    func testCorruptAndPartiallyUnknownFiles() throws {
        try Data("garbage".utf8).write(to: fileURL)
        XCTAssertTrue(HistoryStore(fileURL: fileURL).items.isEmpty)

        // An item written by a future version (unknown provider) is skipped, the rest is kept.
        let good = item("好的")
        var json = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let future = json.replacingOccurrences(of: "\"elevenLabsScribe\"", with: "\"someFutureEngine\"")
            .replacingOccurrences(of: good.id.uuidString, with: UUID().uuidString)
        json = #"{"version":1,"items":[\#(future),\#(json)]}"#
        try Data(json.utf8).write(to: fileURL)
        XCTAssertEqual(HistoryStore(fileURL: fileURL).items, [good])
    }

    func testLoadRepairsOrderAndCap() throws {
        let items = (0..<210).map { i in item("\(i)", secondsAgo: TimeInterval(1_000 - i)) } // oldest first
        let json = #"{"version":1,"items":"# + String(decoding: try JSONEncoder().encode(items), as: UTF8.self) + "}"
        try Data(json.utf8).write(to: fileURL)
        let store = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(store.items.count, 200)
        XCTAssertEqual(store.items.first?.finalText, "209")
        XCTAssertEqual(HistoryStore(fileURL: fileURL).items, store.items)
    }

    func testAddFromBackgroundTask() async throws {
        let store = HistoryStore(fileURL: fileURL)
        let text = "背景加入"
        await Task.detached { store.add(HistoryItem(mode: .dictate, rawTranscript: text, finalText: text,
                                                    sttProvider: .groqWhisperLarge, polishProvider: .anthropic,
                                                    totalMillis: 1)) }.value
        XCTAssertEqual(store.snapshot().map(\.finalText), [text])
        let observed = await MainActor.run { store.items.map(\.finalText) }
        XCTAssertEqual(observed, [text])
    }

    func testConcurrentAdds() {
        let store = HistoryStore(fileURL: fileURL)
        DispatchQueue.concurrentPerform(iterations: 300) { i in
            store.add(HistoryItem(mode: .dictate, rawTranscript: "\(i)", finalText: "\(i)",
                                  sttProvider: .elevenLabsScribe, polishProvider: .off, totalMillis: i))
        }
        XCTAssertEqual(store.snapshot().count, 200)
        drainMainQueue()
        XCTAssertEqual(store.items, store.snapshot())
        XCTAssertEqual(HistoryStore(fileURL: fileURL).items.count, 200)
    }
}
