import XCTest
@testable import ScriberCore
import ScriberShared

/// Wire format of ElevenLabs real-time STT. Server fixtures are frames captured from the live API on
/// 2026-11-22 (scribe_v3_live), with transcript text and the session id replaced by placeholders.
final class RealtimeSTTWireTests: XCTestCase {
    // MARK: Captured server frames

    static let sessionStarted = #"{"config":{"audio_format":"pcm_16000","disable_logging":false,"entity_detection":null,"entity_redaction":null,"entity_redaction_mode":"enumerated_entity_type","filter_background_audio":false,"include_language_detection":false,"include_timestamps":false,"keepalive_interval_ms":null,"keyterms":["Claude Code","Railway"],"language_code":"zh","max_tokens_to_recompute":5,"min_silence_duration_ms":100,"min_speech_duration_ms":100,"model_id":"scribe_v3_live","no_verbatim":true,"sample_rate":16000,"secondary_languages":["en"],"timestamps_granularity":"word","vad_commit_strategy":false,"vad_silence_threshold_secs":1.5,"vad_threshold":0.40000000000000002},"message_type":"session_started","session_id":"0123456789abcdef0123456789abcdef"}"#
    static func partial(_ text: String, turn: Double = 0.58) -> String {
        #"{"message_type":"partial_transcript","text":"\#(text)","turn_probability":\#(turn)}"#
    }
    static func committed(_ text: String) -> String {
        #"{"message_type":"committed_transcript","text":"\#(text)"}"#
    }
    static let authError = #"{"error":"You must be authenticated to use this endpoint.","message_type":"auth_error"}"#
    static let tooManyKeyterms = #"{"error":"Number of keyterms cannot exceed 50. You provided 53 keyterms.","message_type":"invalid_request"}"#
    static let commitThrottled = #"{"error":"Session closed: only 0.00s of uncommitted audio. You need at least 0.3s of uncommitted audio before committing.","message_type":"commit_throttled"}"#
    static let notJSON = #"{"error":"Message must be valid JSON","message_type":"input_error"}"#

    // MARK: Handshake

    func testURLCarriesEveryOptionAsQueryParameters() throws {
        let parameters = RealtimeSTTWire.Parameters(languageCode: "zh-TW", keyterms: ["Claude Code", "C++", "鹿野"])
        let url = RealtimeSTTWire.url(for: parameters)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.elevenlabs.io")
        XCTAssertEqual(components.path, "/v1/speech-to-text/realtime")
        let items = try XCTUnwrap(components.queryItems)
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        XCTAssertEqual(values("model_id"), ["scribe_v3_live"])
        XCTAssertEqual(values("audio_format"), ["pcm_16000"])
        XCTAssertEqual(values("commit_strategy"), ["manual"])
        XCTAssertEqual(values("language_code"), ["zh"], "ISO-639-1, like the batch request")
        XCTAssertEqual(values("secondary_languages"), ["en"])
        XCTAssertEqual(values("no_verbatim"), ["true"])
        XCTAssertEqual(values("keyterms"), ["Claude Code", "C++", "鹿野"], "repeated, as the SDKs send lists")
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"), "a literal + must not turn into a space")
        XCTAssertFalse(url.absoluteString.contains("xi-api-key"))
    }

    func testAutoDetectSendsNoLanguage() throws {
        let url = RealtimeSTTWire.url(for: .init(languageCode: nil, noVerbatim: false))
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        XCTAssertFalse(names.contains("language_code"))
        XCTAssertFalse(names.contains("secondary_languages"))
        XCTAssertFalse(names.contains("no_verbatim"))
    }

    func testKeyIsSentAsHeaderOnly() {
        let request = RealtimeSTTWire.request(for: .init(), apiKey: "test-key-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key-value")
        XCTAssertFalse(request.url!.absoluteString.contains("test-key-value"))
    }

    func testKeytermLimits() {
        // Live: more than 50 → invalid_request (close 1008). The rest goes to the keyterm library.
        let many = (0..<60).map { "term\($0)" }
        let split = RealtimeSTTWire.splitKeyterms(many)
        XCTAssertEqual(split.query.count, 50)
        XCTAssertEqual(split.library, (50..<60).map { "term\($0)" })

        // 1000 characters in total for the query parameter.
        let long = (0..<30).map { String(repeating: Character(UnicodeScalar(UInt8(65 + $0 % 26))), count: 40) + "\($0)" }
        let byLength = RealtimeSTTWire.splitKeyterms(long)
        XCTAssertLessThanOrEqual(byLength.query.reduce(0) { $0 + $1.count }, 1000)
        XCTAssertEqual(byLength.query.count + byLength.library.count, 30)

        // Cleaned, deduplicated, and terms over 50 characters dropped rather than truncated.
        let messy = RealtimeSTTWire.splitKeyterms(["  Claude   Code ", "claude code", "[鹿野]", "", String(repeating: "x", count: 51)])
        XCTAssertEqual(messy.query, ["Claude Code", "鹿野"])
        XCTAssertTrue(messy.library.isEmpty)
    }

    // MARK: Client → server

    func testAudioChunkMatchesTheDocumentedMessage() throws {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(RealtimeSTTWire.audioChunk(pcm).utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["message_type", "audio_base_64", "commit", "sample_rate"])
        XCTAssertEqual(json["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(Data(base64Encoded: json["audio_base_64"] as? String ?? ""), pcm)
        XCTAssertEqual(json["commit"] as? Bool, false)
        XCTAssertEqual(json["sample_rate"] as? Int, 16_000)
    }

    func testCommitIsAnEmptyChunkWithCommitTrue() throws {
        // Identical to the SDKs' commit(): {"message_type":"input_audio_chunk","audio_base_64":"","commit":true,"sample_rate":16000}
        XCTAssertEqual(RealtimeSTTWire.commitMessage,
                       #"{"message_type":"input_audio_chunk","audio_base_64":"","commit":true,"sample_rate":16000}"#)
    }

    func testKeytermLibraryRidesOnTheChunk() throws {
        let message = RealtimeSTTWire.audioChunk(Data([0, 0]), library: ["Claude Code", "鹿野", "say \"hi\""])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        XCTAssertEqual(json["keyterm_library"] as? [String], ["Claude Code", "鹿野", "say \"hi\""])
        XCTAssertEqual(json["commit"] as? Bool, false)
    }

    // MARK: Server → client

    func testDecodesCapturedEvents() {
        XCTAssertEqual(RealtimeSTTWire.decode(Self.sessionStarted),
                       .sessionStarted(sessionID: "0123456789abcdef0123456789abcdef"))
        XCTAssertEqual(RealtimeSTTWire.decode(Self.partial("我今天用 Claude")), .partial("我今天用 Claude"))
        XCTAssertEqual(RealtimeSTTWire.decode(Self.partial("", turn: 0)), .partial(""))
        XCTAssertEqual(RealtimeSTTWire.decode(Self.committed("佔位文字。")), .committed("佔位文字。"))
        XCTAssertEqual(RealtimeSTTWire.decode(Self.committed("")), .committed(""), "a silent segment commits empty text")
        XCTAssertEqual(RealtimeSTTWire.decode(Self.authError),
                       .serverError(type: "auth_error", message: "You must be authenticated to use this endpoint."))
        XCTAssertEqual(RealtimeSTTWire.decode(Self.tooManyKeyterms),
                       .serverError(type: "invalid_request", message: "Number of keyterms cannot exceed 50. You provided 53 keyterms."))
        if case .serverError(let type, _) = RealtimeSTTWire.decode(Self.commitThrottled) {
            XCTAssertEqual(type, "commit_throttled")
        } else { XCTFail("commit_throttled") }
        if case .serverError(let type, _) = RealtimeSTTWire.decode(Self.notJSON) {
            XCTAssertEqual(type, "input_error")
        } else { XCTFail("input_error") }
    }

    func testEveryDocumentedErrorTypeIsAnError() {
        for type in ["error", "auth_error", "quota_exceeded", "commit_throttled", "unaccepted_terms", "rate_limited",
                     "queue_overflow", "resource_exhausted", "session_time_limit_exceeded", "input_error",
                     "invalid_request", "chunk_size_exceeded", "insufficient_audio_activity", "transcriber_error"] {
            let event = RealtimeSTTWire.decode(#"{"message_type":"\#(type)","error":"x"}"#)
            XCTAssertEqual(event, .serverError(type: type, message: "x"), type)
        }
    }

    func testUnknownAndUnrequestedEventsAreNotTranscript() {
        XCTAssertEqual(RealtimeSTTWire.decode(#"{"message_type":"committed_transcript_with_timestamps","text":"重複","words":[]}"#),
                       .ignored("committed_transcript_with_timestamps"))
        XCTAssertEqual(RealtimeSTTWire.decode(#"{"message_type":"brand_new_event","text":"x"}"#), .unknown("brand_new_event"))
        XCTAssertEqual(RealtimeSTTWire.decode(#"{"text":"x"}"#), .unknown("no-type"))
        XCTAssertEqual(RealtimeSTTWire.decode("not json"), .unknown("malformed"))
        XCTAssertEqual(RealtimeSTTWire.decode(#"["array"]"#), .unknown("malformed"))
        XCTAssertEqual(RealtimeSTTWire.decode(#"{"message_type":"warning","warning":"w"}"#), .warning)
        // Only in the JS SDK's types; display text at most.
        XCTAssertEqual(RealtimeSTTWire.decode(#"{"message_type":"final_transcript","text":"x"}"#), .partial("x"))
        // Missing text on a transcript event: empty, not a crash.
        XCTAssertEqual(RealtimeSTTWire.decode(#"{"message_type":"partial_transcript"}"#), .partial(""))
    }

    // MARK: Errors

    func testServerErrorsMapToTheSameMessagesAsBatch() {
        func message(_ type: String) -> String? {
            RealtimeSTTError(.server, serverType: type).errorDescription
        }
        XCTAssertEqual(message("auth_error"), "API key 無效或沒有權限，請到設定檢查")
        XCTAssertEqual(message("quota_exceeded"), "帳戶額度不足，請到服務商後台確認")
        XCTAssertEqual(message("rate_limited"), "用量或頻率超過上限，請稍後再試")
        XCTAssertEqual(message("resource_exhausted"), "服務暫時無法使用（503），請稍後再試")
        XCTAssertEqual(message("invalid_request"), "服務無法處理這次的請求（400）")
        XCTAssertEqual(message("session_time_limit_exceeded"), "即時辨識已達單次時間上限，請再試一次")
        XCTAssertEqual(RealtimeSTTError(.connectTimeout).errorDescription, "即時辨識連線逾時，請再試一次")
        XCTAssertTrue(RealtimeSTTError(.commitTimeout).providerError.isTimeout)
        XCTAssertEqual(RealtimeSTTError(.stalled).errorDescription, "網路連線失敗，即時辨識中斷了")
        XCTAssertEqual(RealtimeSTTError(.closed, closeCode: 1000).errorDescription, "網路連線失敗，即時辨識中斷了")
        XCTAssertEqual(RealtimeSTTError(.handshake, httpStatus: 403).errorDescription, "API key 無效或沒有權限，請到設定檢查")
        XCTAssertEqual(RealtimeSTTError(.handshake, detail: ProviderError.offlineCode).errorDescription,
                       "沒有網路連線，請檢查網路後再試")
        XCTAssertEqual(RealtimeSTTError(.cancelled).errorDescription, "已取消")
    }

    func testLogDescriptionIsContentFree() {
        let error = RealtimeSTTError(.server, serverType: "auth_error", closeCode: 1000)
        XCTAssertEqual(error.logDescription, "reason=server type=auth_error close=1000")
    }

    func testLogSafeMasksKeysAndQuotedValues() {
        let secret = "sk_0123456789abcdef0123456789abcdef"
        let text = RealtimeSTTWire.logSafe("Invalid keyterm '鹿野先生' for key \(secret) and \"another\"", secret: secret)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("鹿野"))
        XCTAssertFalse(text.contains("another"))
        XCTAssertTrue(text.contains("Invalid keyterm"))
    }
}
