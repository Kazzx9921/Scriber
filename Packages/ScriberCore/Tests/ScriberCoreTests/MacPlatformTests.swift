#if os(macOS)
import XCTest
@testable import ScriberCore
import ScriberShared

/// The macOS stand-ins for the iOS App Group: a plain folder and the standard defaults.
final class MacPlatformTests: XCTestCase {
    func testContainerIsAWritableFolderOutsideGroupContainers() throws {
        let url = AppGroup.containerURL
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(url.path.contains("Group Containers"))
        // The test runner is not an app bundle, so it must not share the Mac app's folder.
        XCTAssertFalse(url.path.hasSuffix("Application Support/Scriber"))
        // Stable: the same folder every time (DiagLog calls this for every line).
        XCTAssertEqual(AppGroup.containerURL, url)

        let probe = url.appendingPathComponent("probe-\(UUID().uuidString).txt")
        try Data("ok".utf8).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        XCTAssertEqual(try Data(contentsOf: probe), Data("ok".utf8))
    }

    func testDefaultsAreTheStandardDefaults() {
        XCTAssertTrue(AppGroup.defaults === UserDefaults.standard)
    }

    func testKeychainHasNoSharedAccessGroupOnMac() {
        XCTAssertNil(KeychainStore.sharedAccessGroup)
        XCTAssertNil(KeychainStore.shared.accessGroup)
    }

    func testDiagLogWritesIntoTheContainer() {
        let marker = "mac-platform-test-\(UUID().uuidString)"
        DiagLog.log("test", marker)
        // `read()` runs on the log queue after the pending append.
        XCTAssertTrue(DiagLog.read().contains(marker))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AppGroup.containerURL.appendingPathComponent("diagnostics.log").path))
    }

    func testStoresPersistInTheContainer() throws {
        let folder = AppGroup.containerURL.appendingPathComponent("stores-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let historyURL = folder.appendingPathComponent("history.json")
        let history = HistoryStore(fileURL: historyURL)
        history.add(HistoryItem(mode: .dictate, rawTranscript: "raw", finalText: "final",
                                sttProvider: .groqWhisperTurbo, polishProvider: .off, totalMillis: 10))
        XCTAssertEqual(HistoryStore(fileURL: historyURL).snapshot().map(\.finalText), ["final"])

        let dictionaryURL = folder.appendingPathComponent("dictionary.json")
        DictionaryStore(fileURL: dictionaryURL).add(DictionaryEntry(term: "Scriber", soundsLike: ["scribe er"]))
        XCTAssertEqual(DictionaryStore(fileURL: dictionaryURL).snapshot().map(\.term), ["Scriber"])
    }

    func testUsageStatsRoundTripInStandardDefaults() {
        let before = UsageStats.load()
        defer {
            // Put the runner's defaults back the way they were.
            UsageStats.reset()
            if before.dictations > 0 || before.characters > 0 || before.speakingSeconds > 0 {
                let d = AppGroup.defaults
                d.set(before.dictations, forKey: "stats.dictations")
                d.set(before.characters, forKey: "stats.characters")
                d.set(before.speakingSeconds, forKey: "stats.speakingSeconds")
            }
        }
        UsageStats.reset()
        UsageStats.record(text: "你好 world", speakingSeconds: 1.5)
        let stats = UsageStats.load()
        XCTAssertEqual(stats.dictations, 1)
        XCTAssertEqual(stats.characters, 7)
        XCTAssertEqual(stats.speakingSeconds, 1.5, accuracy: 0.001)
    }
}
#endif
