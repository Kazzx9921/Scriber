import XCTest
@testable import ScriberCore
import ScriberShared

/// Opt-in tests against the real ElevenLabs API (billed). Skipped unless these are set:
///   SCRIBER_LIVE_ELEVENLABS_KEY_FILE  file holding the API key (read here, never printed)
///   SCRIBER_LIVE_AUDIO_WAV            16 kHz mono 16-bit WAV with speech (real-time test)
///   SCRIBER_LIVE_AUDIO_M4A            optional AAC clip (batch test)
/// Example: `say -v Meijia -o s.aiff "…"; afconvert -f WAVE -d LEI16@16000 -c 1 s.aiff s.wav`.
/// Output is limited to timings, counts and lengths.
final class LiveElevenLabsTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func key() throws -> String {
        guard let path = env["SCRIBER_LIVE_ELEVENLABS_KEY_FILE"], !path.isEmpty,
              let key = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw XCTSkip("set SCRIBER_LIVE_ELEVENLABS_KEY_FILE to run live ElevenLabs tests")
        }
        return key
    }

    private func wavSamples() throws -> [Float] {
        guard let path = env["SCRIBER_LIVE_AUDIO_WAV"] else { throw XCTSkip("set SCRIBER_LIVE_AUDIO_WAV") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            if id == "data" {
                return PCM16.floats(fromLittleEndian: data.subdata(in: (offset + 8)..<min(data.count, offset + 8 + size)))
            }
            offset += 8 + size + (size & 1)
        }
        throw XCTSkip("no data chunk in WAV")
    }

    func testValidateKey() async throws {
        let key = try key()
        let message = await STTFactory.validateKey(.elevenLabs, key: key)
        print("LIVE validateKey ok=\(message == nil)")
        XCTAssertNil(message)
        let bogus = await STTFactory.validateKey(.elevenLabs, key: "sk_invalid_live_test_000000000000000000")
        print("LIVE validateKey(bogus) message=\(bogus ?? "nil")")
        XCTAssertNotNil(bogus)
    }

    func testBatchScribeV3() async throws {
        let key = try key()
        guard let path = env["SCRIBER_LIVE_AUDIO_M4A"] else { throw XCTSkip("set SCRIBER_LIVE_AUDIO_M4A") }
        let started = Date()
        let text = try await ElevenLabsScribeSTT(apiKey: key)
            .transcribe(audioFile: URL(fileURLWithPath: path), options: STTOptions(languageCode: "zh", keyterms: ["Claude Code", "Railway"]))
        print(String(format: "LIVE batch scribe_v3 ms=%d chars=%d", Int(Date().timeIntervalSince(started) * 1000), text.count))
        XCTAssertFalse(text.isEmpty)
    }

    /// Feeds the clip like the Mac recorder does (≈21 ms buffers at real-time pace), then stops.
    func testRealtimeSessionEndToEnd() async throws {
        let key = try key()
        let samples = try wavSamples()
        let session = RealtimeSTTSession(apiKey: key, parameters: .init(languageCode: "zh", keyterms: ["Claude Code", "Railway"]),
                                         logTag: "live")
        let counter = Task { () -> (partials: Int, commits: Int, other: [String]) in
            var partials = 0, commits = 0
            var other: [String] = []
            for await event in session.events {
                switch event {
                case .partial: partials += 1
                case .committed: commits += 1
                case .started: other.append("started")
                case .error(let e): other.append("error \(e.logDescription)")
                case .closed(let code): other.append("closed \(code ?? -1)")
                }
            }
            return (partials, commits, other)
        }
        session.start()
        let buffer = 341
        var index = 0
        let clock = ContinuousClock()
        let begin = clock.now
        while index < samples.count {
            let end = min(samples.count, index + buffer)
            session.append(samples: Array(samples[index..<end]))
            index = end
            try await clock.sleep(until: begin + .milliseconds(index * 1000 / 16_000))
        }
        let stopped = Date()
        let transcript = try await session.finish()
        let stopToText = Int(Date().timeIntervalSince(stopped) * 1000)
        let counts = await counter.value
        let m = session.currentMetrics
        print("LIVE realtime audio=\(String(format: "%.1f", m.audioSecondsSent))s connectMs=\(m.connectMillis ?? -1) "
              + "firstPartialMs=\(m.firstPartialMillis ?? -1) finalCommitMs=\(m.finalCommitMillis ?? -1) "
              + "stopToTranscriptMs=\(stopToText) chunks=\(m.chunksSent) commits=\(m.commitsSent) "
              + "partials=\(counts.partials) committed=\(counts.commits) events=\(counts.other) chars=\(transcript.count)")
        XCTAssertFalse(transcript.isEmpty)

        // The final text through the same post-processing as the batch path.
        let pipeline = DictationPipeline(
            config: {
                PipelineConfig(sttProvider: .elevenLabsScribe, polishProvider: .off, forceTraditional: true,
                               spaceBetweenCJKAndLatin: true, translateTarget: "English")
            },
            dictionary: DictionaryStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("live-\(UUID().uuidString).json")),
            makeSTT: { _ in throw ProviderError.cancelled }, makePolish: { _ in nil })
        let result = try await pipeline.run(transcript: transcript, request: DictationRequest(), sttMillis: stopToText)
        print("LIVE realtime raw simplified=\(ZhTW.containsSimplified(transcript)) final simplified=\(ZhTW.containsSimplified(result.finalText)) "
              + "finalChars=\(result.finalText.count) hasTai=\(result.finalText.contains("台")) hasKeyterm=\(result.finalText.contains("Claude Code"))")
        XCTAssertFalse(ZhTW.containsSimplified(result.finalText))
    }

    func testRealtimeRejectsABadKey() async throws {
        _ = try key() // opt-in gate only; the request uses a made-up key
        let session = RealtimeSTTSession(apiKey: "sk_invalid_live_test_000000000000000000", parameters: .init(), logTag: "live-bad")
        session.start()
        do {
            _ = try await session.finish()
            XCTFail("expected an auth error")
        } catch let error as RealtimeSTTError {
            print("LIVE realtime bad key → \(error.logDescription) message=\(error.errorDescription ?? "")")
            XCTAssertEqual(error.reason, .server)
            XCTAssertEqual(error.serverType, "auth_error")
        }
    }
}
