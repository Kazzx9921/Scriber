import XCTest
@testable import ScriberCore
import ScriberShared

/// Opt-in file-transcription checks against the real ElevenLabs API (billed). Skipped unless set:
///   SCRIBER_LIVE_ELEVENLABS_KEY_FILE  file holding the API key (read here, never printed)
///   SCRIBER_LIVE_LONG_AUDIO           a speech file of about a minute (two voices for the speaker test)
///   SCRIBER_LIVE_SHORT_AUDIO          optional short clip for the response-shape check
/// Prints only counts, timings, booleans and field names.
@MainActor
final class LiveFileTranscriptionTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberLiveFile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func key() throws -> String {
        guard let path = env["SCRIBER_LIVE_ELEVENLABS_KEY_FILE"], !path.isEmpty,
              let key = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw XCTSkip("set SCRIBER_LIVE_ELEVENLABS_KEY_FILE to run live file-transcription tests")
        }
        return key
    }

    private func audio(_ name: String) throws -> URL {
        guard let path = env[name], FileManager.default.fileExists(atPath: path) else { throw XCTSkip("set \(name)") }
        return URL(fileURLWithPath: path)
    }

    private func environment(key: String, targetSeconds: TimeInterval) -> TranscriptionEnvironment {
        var environment = TranscriptionEnvironment.live(store: TranscriptStore(directory: folder.appendingPathComponent("store")),
                                                        workRoot: folder.appendingPathComponent("work"))
        environment.policy.targetSeconds = targetSeconds
        environment.policy.searchWindowSeconds = 6
        environment.makeTranscriber = { _ in ElevenLabsFileTranscriber(apiKey: key, session: ProviderHTTP.fileSession) }
        environment.keyterms = { ["Claude Code", "Railway", "Supabase"] }
        environment.postProcessor = { language in
            TranscriptPostProcessor.make(language: language, entries: [], forceTraditional: true, spaceBetweenCJKAndLatin: true)
        }
        return environment
    }

    private func run(_ queue: TranscriptionQueue, _ url: URL, options: TranscriptionOptions) async throws -> TranscriptionJob {
        let job = try XCTUnwrap(queue.add([url], engine: .elevenLabsScribe, options: options).first)
        let deadline = Date().addingTimeInterval(300)
        while job.phase != .done, Date() < deadline {
            if case .failed(let message) = job.phase {
                XCTFail("job failed: \(message)")
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return job
    }

    /// Chunked path: ~20 s segments cut at pauses, three requests in parallel.
    func testChunkedTranscription() async throws {
        let key = try key()
        let url = try audio("SCRIBER_LIVE_LONG_AUDIO")
        let environment = environment(key: key, targetSeconds: 20)
        let queue = TranscriptionQueue(environment: environment, restore: false)
        let started = Date()
        let job = try await run(queue, url, options: TranscriptionOptions(timestamps: true, speakers: false))
        XCTAssertEqual(job.phase, .done)
        let record = try XCTUnwrap(environment.store.record(id: try XCTUnwrap(job.transcriptID)))
        let text = TranscriptExport.plainText(record.paragraphs, style: .init(timestamps: false, speakers: false), duration: record.duration)
        print(String(format: "LIVE file chunked: audio=%.1fs segments=%d failed=%d wall=%dms paragraphs=%d cues=%d chars=%d granularity=%@ simplified=%@ keytermsSpelled=%@ tai=%@",
                     record.duration, job.segmentsTotal, job.failedSegments.count, Int(Date().timeIntervalSince(started) * 1000),
                     record.paragraphs.count, record.cues.count, record.characterCount, record.granularity.rawValue,
                     ZhTW.containsSimplified(text) ? "yes" : "no",
                     (text.contains("Claude Code") && text.contains("Railway") && text.contains("Supabase")) ? "yes" : "no",
                     text.contains("臺") ? "臺" : "ok"))
        XCTAssertGreaterThanOrEqual(job.segmentsTotal, 2)
        XCTAssertTrue(job.failedSegments.isEmpty)
        XCTAssertEqual(record.granularity, .word)
        XCTAssertFalse(ZhTW.containsSimplified(text))
        XCTAssertNotNil(TranscriptExport.srt(record))
    }

    /// Speaker labels: one request with diarize=true.
    func testSpeakerLabels() async throws {
        let key = try key()
        let url = try audio("SCRIBER_LIVE_LONG_AUDIO")
        let environment = environment(key: key, targetSeconds: 20)
        let queue = TranscriptionQueue(environment: environment, restore: false)
        let started = Date()
        let job = try await run(queue, url, options: TranscriptionOptions(timestamps: true, speakers: true))
        XCTAssertEqual(job.phase, .done)
        let record = try XCTUnwrap(environment.store.record(id: try XCTUnwrap(job.transcriptID)))
        let speakers = Set(record.paragraphs.compactMap(\.speaker))
        let changes = zip(record.paragraphs, record.paragraphs.dropFirst()).filter { $0.speaker != $1.speaker }.count
        print("LIVE file speakers: single=\(job.singleRequest) segments=\(job.segmentsTotal) wall=\(Int(Date().timeIntervalSince(started) * 1000))ms paragraphs=\(record.paragraphs.count) speakers=\(speakers.count) speakerChanges=\(changes) cues=\(record.cues.count)")
        XCTAssertTrue(job.singleRequest)
        XCTAssertTrue(record.hasSpeakers)
        XCTAssertGreaterThanOrEqual(speakers.count, 2)
    }

    /// Raw response shape with word timestamps and diarization (field names only).
    func testResponseShape() async throws {
        let key = try key()
        let url = try audio("SCRIBER_LIVE_SHORT_AUDIO")
        let copy = folder.appendingPathComponent("segment-0000." + url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        let engine = ElevenLabsFileTranscriber(apiKey: key, session: ProviderHTTP.fileSession)
        var request = URLRequest(url: ElevenLabsScribeSTT.baseURL.appendingPathComponent("v1/speech-to-text"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let data = try await ProviderHTTP.uploadMultipart(
            request, fields: engine.fields(FileSTTRequest(languageCode: "zh", keyterms: ["Claude Code"], diarize: true, audioSeconds: 10)),
            file: copy, timeout: 120, session: ProviderHTTP.fileSession, secret: key)
        let json = try ProviderHTTP.decodeJSONObject(data)
        let words = json["words"] as? [[String: Any]] ?? []
        let wordKeys = Set(words.flatMap(\.keys)).sorted()
        let types = Set(words.compactMap { $0["type"] as? String }).sorted()
        let speakers = Set(words.compactMap { $0["speaker_id"] as? String }).count
        print("LIVE shape: top=\(json.keys.sorted()) wordKeys=\(wordKeys) types=\(types) words=\(words.count) speakers=\(speakers)")
        let parsed = try ElevenLabsFileTranscriber.parse(data)
        XCTAssertEqual(parsed.granularity, .word)
        XCTAssertFalse(parsed.units.isEmpty)
        XCTAssertTrue(parsed.units.allSatisfy { $0.end >= $0.start })
    }
}
