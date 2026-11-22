import AVFoundation
import XCTest

final class CustomCueFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberCueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// A WAV file with a quiet tone (written to disk only, never played).
    private func tone(_ seconds: Double, name: String, rate: Double = 44_100) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = Float(sin(Double(i) * 0.05)) * 0.1 }
        try file.write(from: buffer)
        return url
    }

    func testThresholds() {
        XCTAssertEqual(CustomCueFiles.check(duration: 0.4, bytes: 1_000), .ok(0.4))
        XCTAssertEqual(CustomCueFiles.check(duration: 2.0, bytes: 1_000), .ok(2.0))
        XCTAssertEqual(CustomCueFiles.check(duration: 2.5, bytes: 1_000), .long(2.5))
        XCTAssertEqual(CustomCueFiles.check(duration: 5.0, bytes: 1_000), .long(5.0))
        XCTAssertEqual(CustomCueFiles.check(duration: 5.1, bytes: 1_000), .tooLong(5.1))
        XCTAssertEqual(CustomCueFiles.check(duration: nil, bytes: 1_000), .unreadable)
        XCTAssertEqual(CustomCueFiles.check(duration: 0, bytes: 1_000), .unreadable)
        XCTAssertEqual(CustomCueFiles.check(duration: .nan, bytes: 1_000), .unreadable)
        XCTAssertEqual(CustomCueFiles.check(duration: 1, bytes: CustomCueFiles.maxBytes + 1), .tooBig)
        XCTAssertTrue(CustomCueFiles.Check.long(3).isAccepted)
        XCTAssertFalse(CustomCueFiles.Check.tooLong(6).isAccepted)
    }

    func testRealFilesAreMeasured() throws {
        XCTAssertEqual(CustomCueFiles.duration(of: try tone(0.5, name: "a.wav")) ?? 0, 0.5, accuracy: 0.01)
        guard case .long = CustomCueFiles.check(try tone(3, name: "b.wav")) else { return XCTFail("3 s should warn") }
        guard case .tooLong = CustomCueFiles.check(try tone(6, name: "c.wav")) else { return XCTFail("6 s should be refused") }
        let junk = folder.appendingPathComponent("junk.mp3")
        try Data("not audio at all".utf8).write(to: junk)
        XCTAssertEqual(CustomCueFiles.check(junk), .unreadable)
    }

    func testImportCopiesIntoItsOwnFolder() throws {
        let store = CustomCueFiles(directory: folder.appendingPathComponent("Sounds"))
        let source = try tone(0.3, name: "My Ding.WAV")
        let imported = try store.importFile(source, for: .start)
        XCTAssertEqual(imported.displayName, "My Ding")
        XCTAssertTrue(imported.fileName.hasPrefix("start-"))
        XCTAssertTrue(imported.fileName.hasSuffix(".wav"))
        guard case .ok = imported.check else { return XCTFail("short file is fine") }
        // Keeps working after the original is gone.
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(store.exists(imported.fileName))
        XCTAssertNotNil(CustomCueFiles.duration(of: store.url(for: imported.fileName)))

        store.remove(imported.fileName)
        XCTAssertFalse(store.exists(imported.fileName))
    }

    func testRefusedFilesAreNotCopied() throws {
        let store = CustomCueFiles(directory: folder.appendingPathComponent("Sounds"))
        XCTAssertThrowsError(try store.importFile(try tone(6, name: "long.wav"), for: .stop)) { error in
            guard case CustomCueFiles.ImportError.rejected(.tooLong) = error else { return XCTFail("\(error)") }
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
        XCTAssertTrue(contents.isEmpty)
    }

    func testRemoveIgnoresPathsOutsideTheFolder() throws {
        let store = CustomCueFiles(directory: folder.appendingPathComponent("Sounds"))
        let outside = try tone(0.2, name: "outside.wav")
        store.remove("../outside.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        store.remove(nil)
    }
}
