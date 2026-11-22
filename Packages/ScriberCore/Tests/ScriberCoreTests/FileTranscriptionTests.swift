import AVFoundation
import XCTest
@testable import ScriberCore
import ScriberShared

/// URLProtocol stub for upload tasks, with response headers (Retry-After).
final class UploadStub: URLProtocol {
    struct Reply { var status = 200; var body = Data(); var headers: [String: String] = [:] }
    private static let lock = NSLock()
    private static var reply = Reply()
    private static var _seen: [URLRequest] = []

    static func install(_ reply: Reply) {
        lock.lock(); self.reply = reply; _seen = []; lock.unlock()
    }
    static var seen: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _seen }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self._seen.append(request)
        let reply = Self.reply
        Self.lock.unlock()
        var headers = reply.headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class FileTranscriptionTests: XCTestCase {
    private func field(_ fields: [(String, String)], _ name: String) -> [String] {
        fields.filter { $0.0 == name }.map(\.1)
    }

    // MARK: Requests

    func testScribeRequestAsksForWordTimingsAndOptionalSpeakers() {
        let engine = ElevenLabsFileTranscriber(apiKey: "k", session: UploadStub.session())
        let plain = engine.fields(FileSTTRequest(languageCode: "zh", keyterms: ["Claude Code", "Claude code", "bad[term]"],
                                                 diarize: false, audioSeconds: 300))
        XCTAssertEqual(field(plain, "model_id"), ["scribe_v3"])
        XCTAssertEqual(field(plain, "timestamps_granularity"), ["word"])
        XCTAssertEqual(field(plain, "diarize"), ["false"])
        XCTAssertEqual(field(plain, "language_code"), ["zh"])
        XCTAssertEqual(field(plain, "secondary_language_codes"), ["en"])
        XCTAssertEqual(field(plain, "tag_audio_events"), ["false"])
        XCTAssertEqual(field(plain, "no_verbatim"), ["true"])
        XCTAssertEqual(field(plain, "keyterms"), ["Claude Code", "badterm"], "same keyterm rules as dictation")
        let speakers = engine.fields(FileSTTRequest(languageCode: nil, diarize: true, audioSeconds: 3600))
        XCTAssertEqual(field(speakers, "diarize"), ["true"])
        XCTAssertTrue(field(speakers, "language_code").isEmpty, "auto-detect sends no language")
    }

    func testWhisperRequestAsksForSegmentTimings() {
        let engine = WhisperFileTranscriber(engine: .groqWhisperTurbo, apiKey: "k", model: "whisper-large-v3-turbo",
                                            session: UploadStub.session())
        let fields = engine.fields(FileSTTRequest(languageCode: "zh", keyterms: ["Scriber"], audioSeconds: 300))
        XCTAssertEqual(field(fields, "response_format"), ["verbose_json"])
        XCTAssertEqual(field(fields, "timestamp_granularities[]"), ["segment"])
        XCTAssertEqual(field(fields, "language"), ["zh"])
        XCTAssertTrue(field(fields, "prompt").first?.contains("Scriber") ?? false)
        let auto = engine.fields(FileSTTRequest(languageCode: nil, keyterms: [], audioSeconds: 300))
        XCTAssertTrue(field(auto, "prompt").isEmpty, "no zh-Hant lead sentence when the language is detected")
    }

    func testTimeoutGrowsWithAudioLength() {
        XCTAssertEqual(FileSTTRequest(languageCode: nil, audioSeconds: 300).timeout, 300)
        XCTAssertEqual(FileSTTRequest(languageCode: nil, audioSeconds: 3 * 3600).timeout, 5550)
        XCTAssertEqual(FileSTTRequest(languageCode: nil, audioSeconds: 10 * 3600).timeout, 2 * 3600)
    }

    func testCapabilities() {
        XCTAssertEqual(FileTranscriberFactory.capabilities(of: .elevenLabsScribe), .elevenLabs)
        XCTAssertEqual(FileTranscriberFactory.capabilities(of: .groqWhisperLarge).granularity, .segment)
        XCTAssertFalse(FileTranscriberFactory.capabilities(of: .custom).diarization)
        XCTAssertEqual(FileTranscriptionCapabilities.elevenLabs.maxRequestSeconds, 15 * 3600)
    }

    func testFactoryNeedsAKey() {
        let keys = KeychainStore(service: "com.geekaz.Scriber.tests.file-\(UUID().uuidString)", accessGroup: nil)
        XCTAssertThrowsError(try FileTranscriberFactory.make(.groqWhisperLarge, keys: keys, session: UploadStub.session())) {
            guard case ProviderError.missingAPIKey(.groq)? = $0 as? ProviderError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Responses

    func testParseScribeWordsWithSpacingAndSpeakers() throws {
        let json: [String: Any] = [
            "language_code": "zho", "language_probability": 0.98, "text": "Hello 大家好",
            "words": [
                ["text": "Hello", "start": 0.1, "end": 0.5, "type": "word", "speaker_id": "speaker_0", "logprob": -0.1],
                ["text": " ", "start": 0.5, "end": 0.6, "type": "spacing", "speaker_id": "speaker_0", "logprob": 0],
                ["text": "(笑聲)", "start": 0.6, "end": 0.9, "type": "audio_event", "speaker_id": "speaker_0", "logprob": 0],
                ["text": "大家", "start": 1.0, "end": 1.3, "type": "word", "speaker_id": "speaker_1", "logprob": -0.2],
                ["text": "好", "start": NSNull(), "end": NSNull(), "type": "word", "speaker_id": "speaker_1", "logprob": -0.2],
            ],
        ]
        let parsed = try ElevenLabsFileTranscriber.parse(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(parsed.granularity, .word)
        XCTAssertEqual(parsed.units.map(\.text), ["Hello", " 大家", "好"])
        XCTAssertEqual(parsed.units.map(\.speaker), ["speaker_0", "speaker_1", "speaker_1"])
        XCTAssertEqual(parsed.units[2].start, 1.3, "missing times fall back to the previous word's end")
        XCTAssertEqual(parsed.units.map(\.text).joined(), "Hello 大家好")
    }

    func testParseWhisperSegmentsDropsHallucinations() throws {
        let json: [String: Any] = [
            "text": "大家好。謝謝觀看",
            "segments": [
                ["id": 0, "start": 0.0, "end": 2.5, "text": "大家好。", "avg_logprob": -0.2, "no_speech_prob": 0.01],
                ["id": 1, "start": 30.0, "end": 32.0, "text": "謝謝觀看", "avg_logprob": -0.3, "no_speech_prob": 0.2],
                ["id": 2, "start": 40.0, "end": 42.0, "text": "嗯嗯", "avg_logprob": -1.4, "no_speech_prob": 0.9],
                ["id": 3, "start": 50.0, "end": 52.0, "text": " 再見。", "avg_logprob": -0.4, "no_speech_prob": 0.1],
            ],
        ]
        let parsed = try WhisperFileTranscriber.parse(try JSONSerialization.data(withJSONObject: json), prompt: "")
        XCTAssertEqual(parsed.granularity, .segment)
        XCTAssertEqual(parsed.units.map(\.text), ["大家好。", " 再見。"])
        XCTAssertEqual(parsed.text, "大家好。 再見。")
        XCTAssertEqual(parsed.units.map(\.start), [0, 50])
        // Plain json (no segments) still works.
        let plain = try WhisperFileTranscriber.parse(Data(#"{"text":"你好"}"#.utf8), prompt: "")
        XCTAssertEqual(plain, TimedText(text: "你好"))
    }

    // MARK: Upload

    func testMultipartBodyStreamsTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberMultipart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("segment-0001.m4a")
        let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try payload.write(to: audio)
        let body = folder.appendingPathComponent("body")
        try MultipartFileBody.write(fields: [("model_id", "scribe_v3"), ("keyterms", "Claude \"Code\"")], file: audio,
                                    mimeType: "audio/mp4", boundary: "XYZ", to: body)
        let data = try Data(contentsOf: body)
        let head = String(decoding: data.prefix(400), as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("--XYZ\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v3\r\n"))
        XCTAssertTrue(head.contains("Claude \"Code\""))
        XCTAssertTrue(head.contains("name=\"file\"; filename=\"segment-0001.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n"))
        XCTAssertEqual(data.suffix(11), Data("\r\n--XYZ--\r\n".utf8))
        let marker = Data("Content-Type: audio/mp4\r\n\r\n".utf8)
        let start = try XCTUnwrap(data.range(of: marker)).upperBound
        XCTAssertEqual(data[start..<(start + payload.count)], payload)
    }

    func testRateLimitCarriesRetryAfter() async throws {
        let file = try makeTempAudioFile("segment-0000.m4a", bytes: 2048)
        UploadStub.install(.init(status: 429, body: Data(#"{"detail":{"status":"too_many_concurrent_requests","message":"slow down"}}"#.utf8),
                                 headers: ["Retry-After": "7"]))
        let engine = ElevenLabsFileTranscriber(apiKey: "sk_test_key", session: UploadStub.session())
        do {
            _ = try await engine.transcribe(file: file, request: FileSTTRequest(languageCode: "zh", audioSeconds: 10))
            XCTFail("expected 429")
        } catch let error as RateLimitedError {
            XCTAssertEqual(error.retryAfter, 7)
        }
        let request = try XCTUnwrap(UploadStub.seen.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "sk_test_key")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text")
        // The temporary request body is removed.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["segment-0000.m4a"])
    }

    func testSuccessfulUploadParsesWords() async throws {
        let file = try makeTempAudioFile("segment-0003.m4a", bytes: 2048)
        UploadStub.install(.init(status: 200, body: Data(#"{"text":"你好","words":[{"text":"你好","start":0.2,"end":0.6,"type":"word"}]}"#.utf8)))
        let engine = ElevenLabsFileTranscriber(apiKey: "k", session: UploadStub.session())
        let text = try await engine.transcribe(file: file, request: FileSTTRequest(languageCode: "zh", audioSeconds: 10))
        XCTAssertEqual(text.units.first?.start, 0.2)
        XCTAssertEqual(ProviderHTTP.retryAfter("abc"), nil)
        XCTAssertEqual(ProviderHTTP.retryAfter("9999"), 300)
    }
}

/// Real decoding through AVFoundation of files generated here (no network, no microphone).
final class AudioIngestTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberIngest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func tone(seconds: Double, rate: Double, frequency: Double = 440) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sin(2 * .pi * frequency * Double($0) / rate)) * 0.4 }
    }

    private func readAll(_ source: any PCMSource) throws -> [Float] {
        var all: [Float] = []
        while let chunk = try source.read() { all += chunk }
        return all
    }

    func testDecodesAWAVWrittenWithWAVFileWriter() async throws {
        let url = folder.appendingPathComponent("tone.wav")
        let writer = try WAVFileWriter(url: url)
        try writer.append(tone(seconds: 2, rate: 16_000))
        try writer.finish()

        let probe = try await AudioIngest.probe(url)
        XCTAssertEqual(probe.duration ?? 0, 2, accuracy: 0.01)
        XCTAssertFalse(probe.hasVideo)
        let samples = try readAll(try await AudioIngest.open(url, from: 0))
        XCTAssertEqual(samples.count, 32_000, accuracy: 64)
        XCTAssertEqual(PCMLevel.rms(samples), Float(0.4 / 2.squareRoot()), accuracy: 0.02)
        let tail = try readAll(try await AudioIngest.open(url, from: 1.5))
        XCTAssertEqual(tail.count, 8_000, accuracy: 64, "decoding can start part-way (resume)")
    }

    /// 44.1 kHz stereo in → 16 kHz mono out, same duration, the average of the channels (no gain).
    func testResamplesAndDownmixes() async throws {
        let url = folder.appendingPathComponent("stereo.aiff")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                                              AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                                              AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let samples = tone(seconds: 1.5, rate: 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<2 {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
        if #available(macOS 15.0, iOS 18.0, *) { file.close() }

        let decoded = try readAll(try await AudioIngest.open(url, from: 0))
        XCTAssertEqual(decoded.count, 24_000, accuracy: 100)
        XCTAssertEqual(PCMLevel.rms(Array(decoded[2000..<22000])), Float(0.4 / 2.squareRoot()), accuracy: 0.03)
    }

    func testNonMediaFileIsUnreadable() async throws {
        let url = folder.appendingPathComponent("notes.mp3")
        try Data("this is not audio".utf8).write(to: url)
        do {
            _ = try await AudioIngest.probe(url)
            XCTFail("expected an error")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .unreadable)
            XCTAssertEqual(error.errorDescription, "這個檔案打不開，可能不是音訊或影片，或格式不支援")
        }
    }

    func testAACSegmentRoundTrip() async throws {
        let writer = try AudioIngest.makeSegmentWriter(baseURL: folder.appendingPathComponent("segment-0000"))
        XCTAssertEqual(writer.url.pathExtension, "m4a")
        let samples = tone(seconds: 3, rate: 16_000)
        try writer.append(samples[0..<20_000])
        try writer.append(samples[20_000...])
        let bytes = try writer.finish()
        XCTAssertGreaterThan(bytes, 1_000)
        XCTAssertLessThan(bytes, 40_000, "AAC at 16 kHz mono is small (3 s)")
        let decoded = try readAll(try await AudioIngest.open(writer.url, from: 0))
        XCTAssertEqual(decoded.count, 48_000, accuracy: 2_100)
    }

    /// The whole job on a real file: AVFoundation decoding, quiet-point cuts, AAC segments, stub engine.
    @MainActor
    func testJobOnARealFile() async throws {
        // 26 s: tone with pauses at 9–10 s and 18–19 s; segments of ≤ 10 s.
        let url = folder.appendingPathComponent("talk.wav")
        let writer = try WAVFileWriter(url: url)
        var all = tone(seconds: 26, rate: 16_000)
        for range in [9.0..<10.0, 18.0..<19.0] {
            for i in Int(range.lowerBound * 16_000)..<Int(range.upperBound * 16_000) { all[i] = 0 }
        }
        try writer.append(all)
        try writer.finish()

        let engine = StubEngine()
        var env = TranscriptionEnvironment.live(store: TranscriptStore(directory: folder.appendingPathComponent("store")),
                                                workRoot: folder.appendingPathComponent("work"))
        env.policy.targetSeconds = 10
        env.policy.searchWindowSeconds = 2
        env.policy.hardCapSeconds = 20
        env.makeTranscriber = { _ in engine }
        env.keyterms = { [] }
        env.postProcessor = { _ in .identity }
        let queue = TranscriptionQueue(environment: env, restore: false)
        let job = try XCTUnwrap(queue.add([url], engine: .elevenLabsScribe, options: .init()).first)
        let deadline = Date().addingTimeInterval(20)
        while job.phase != .done, Date() < deadline {
            if case .failed(let message) = job.phase { XCTFail(message); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(job.phase, .done)
        XCTAssertEqual(job.segmentsTotal, 3)
        XCTAssertEqual(job.duration ?? 0, 26, accuracy: 0.1)
        XCTAssertEqual(engine.calls.count, 3)
        XCTAssertEqual(env.store.record(id: try XCTUnwrap(job.transcriptID))?.paragraphs.count, 3)
    }
}
