import XCTest
@testable import ScriberCore
import ScriberShared

// MARK: - URLProtocol stub shared by the STT / Polish / Pipeline tests (agent A)

/// Intercepts every request on sessions made by `ScriberHTTPStub.session()`.
final class ScriberHTTPStub: URLProtocol {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        var delay: TimeInterval = 0
        var error: URLError?

        static func json(_ object: Any, status: Int = 200, delay: TimeInterval = 0) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), delay: delay)
        }
    }

    struct Captured {
        var request: URLRequest
        var body: Data
        var bodyString: String { String(decoding: body, as: UTF8.self) }
        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
    }

    private static let lock = NSLock()
    private static var handler: ((Captured) -> Reply)?
    private static var log: [Captured] = []

    static func install(_ handler: @escaping (Captured) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        log = []
    }

    static var requests: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriberHTTPStub.self]
        return URLSession(configuration: config)
    }

    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let captured = Captured(request: request, body: Self.readBody(of: request))
        Self.lock.lock()
        Self.log.append(captured)
        let handler = Self.handler
        Self.lock.unlock()
        let reply = handler?(captured) ?? Reply(status: 500)

        let deliver: () -> Void = { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stopped = self.stopped
            self.stateLock.unlock()
            guard !stopped else { return }
            if let error = reply.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        stateLock.lock(); stopped = true; stateLock.unlock()
    }

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Small fake audio file on disk.
func makeTempAudioFile(_ name: String = "clip.m4a", bytes: Int = 64) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScriberSTTTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
}

/// Parses a multipart body into (name, value) pairs; file parts get their filename as value.
func multipartFields(_ captured: ScriberHTTPStub.Captured) -> [(name: String, value: String)] {
    guard let contentType = captured.header("Content-Type"),
          let range = contentType.range(of: "boundary=") else { return [] }
    let boundary = String(contentType[range.upperBound...])
    let text = String(decoding: captured.body, as: UTF8.self)
    var fields: [(String, String)] = []
    for part in text.components(separatedBy: "--\(boundary)") {
        guard let headerEnd = part.range(of: "\r\n\r\n") else { continue }
        let headers = String(part[..<headerEnd.lowerBound])
        guard let nameRange = headers.range(of: "name=\"") else { continue }
        let afterName = headers[nameRange.upperBound...]
        let name = String(afterName[..<afterName.firstIndex(of: "\"")!])
        var value = String(part[headerEnd.upperBound...])
        if value.hasSuffix("\r\n") { value.removeLast() } // "\r\n" is one Character
        if let fileRange = headers.range(of: "filename=\"") {
            let afterFile = headers[fileRange.upperBound...]
            value = "file:" + String(afterFile[..<afterFile.firstIndex(of: "\"")!])
        }
        fields.append((name, value))
    }
    return fields
}

// MARK: - STT tests

final class STTProviderTests: XCTestCase {
    private let fakeKey = "test-key-not-real"

    // MARK: ElevenLabs Scribe v3

    func testScribeRequestShape() async throws {
        ScriberHTTPStub.install { _ in .json(["text": " 我們明天開會。 ", "language_code": "zho"]) }
        let stt = ElevenLabsScribeSTT(apiKey: fakeKey, session: ScriberHTTPStub.session())
        let audio = try makeTempAudioFile()
        let text = try await stt.transcribe(audioFile: audio,
                                            options: STTOptions(languageCode: "zh-TW", keyterms: ["Claude Code", "鹿野"]))
        XCTAssertEqual(text, "我們明天開會。")

        let captured = try XCTUnwrap(ScriberHTTPStub.requests.first)
        XCTAssertEqual(captured.request.httpMethod, "POST")
        XCTAssertEqual(captured.request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(captured.header("xi-api-key"), fakeKey)
        XCTAssertTrue(captured.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

        let fields = multipartFields(captured)
        func values(_ name: String) -> [String] { fields.filter { $0.name == name }.map(\.value) }
        XCTAssertEqual(values("model_id"), ["scribe_v3"])
        XCTAssertEqual(values("language_code"), ["zh"])
        XCTAssertEqual(values("secondary_language_codes"), ["en"])
        XCTAssertEqual(values("tag_audio_events"), ["false"])
        XCTAssertEqual(values("diarize"), ["false"])
        XCTAssertEqual(values("timestamps_granularity"), ["none"])
        XCTAssertEqual(values("no_verbatim"), ["true"])
        XCTAssertEqual(values("keyterms"), ["Claude Code", "鹿野"])
        XCTAssertEqual(values("file"), ["file:clip.m4a"])
        XCTAssertTrue(captured.bodyString.contains("Content-Type: audio/mp4"))
    }

    func testScribeOmitsLanguageWhenAutoDetect() async throws {
        ScriberHTTPStub.install { _ in .json(["text": "hello"]) }
        let stt = ElevenLabsScribeSTT(apiKey: fakeKey, session: ScriberHTTPStub.session())
        _ = try await stt.transcribe(audioFile: try makeTempAudioFile(), options: STTOptions())
        let names = multipartFields(try XCTUnwrap(ScriberHTTPStub.requests.first)).map(\.name)
        XCTAssertFalse(names.contains("language_code"))
        XCTAssertFalse(names.contains("secondary_language_codes"))
        XCTAssertFalse(names.contains("keyterms"))
    }

    func testScribeKeytermLimits() {
        let long = String(repeating: "a", count: 51)
        let terms = ["Claude Code", "  Claude   Code ", "claude code", long, "one two three four five six",
                     "a<b>", "[x]", "  ", "Supabase Vault", "鹿野"]
        XCTAssertEqual(ElevenLabsScribeSTT.sanitizedKeyterms(terms), ["Claude Code", "ab", "x", "Supabase Vault", "鹿野"])

        let many = (0..<500).map { "term\($0)" }
        XCTAssertEqual(ElevenLabsScribeSTT.sanitizedKeyterms(many).count, ElevenLabsScribeSTT.maxKeyterms)
        XCTAssertEqual(ElevenLabsScribeSTT.maxKeyterms, 100)
        XCTAssertEqual(ElevenLabsScribeSTT.sanitizedKeyterms([String(repeating: "字", count: 50)]).count, 1)
    }

    func testScribeHTTPErrorsMapToFriendlyMessages() async throws {
        ScriberHTTPStub.install { _ in
            .json(["detail": ["status": "invalid_api_key", "message": "Invalid API key: \(self.fakeKey)"]], status: 401)
        }
        let stt = ElevenLabsScribeSTT(apiKey: fakeKey, session: ScriberHTTPStub.session())
        do {
            _ = try await stt.transcribe(audioFile: try makeTempAudioFile(), options: STTOptions())
            XCTFail("expected error")
        } catch let error as ProviderError {
            guard case .http(let status, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 401)
            XCTAssertTrue(message.contains("invalid_api_key"))
            XCTAssertFalse(message.contains(fakeKey), "server message must be scrubbed of the key")
            XCTAssertEqual(error.errorDescription, "API key 無效或沒有權限，請到設定檢查")
            XCTAssertFalse(error.errorDescription!.contains(fakeKey))
        }
    }

    func testMissingAudioFile() async {
        let stt = ElevenLabsScribeSTT(apiKey: fakeKey, session: ScriberHTTPStub.session())
        do {
            _ = try await stt.transcribe(audioFile: URL(fileURLWithPath: "/nonexistent/clip.m4a"), options: STTOptions())
            XCTFail("expected error")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "讀不到錄音檔，請再錄一次")
        }
    }

    // MARK: Groq Whisper

    func testWhisperRequestShape() async throws {
        ScriberHTTPStub.install { _ in .json(["text": "我剛剛 push 了一個 PR", "x_groq": ["id": "req_1"]]) }
        let stt = GroqWhisperSTT(apiKey: fakeKey, model: .largeV3Turbo, session: ScriberHTTPStub.session())
        let text = try await stt.transcribe(audioFile: try makeTempAudioFile("a.wav"),
                                            options: STTOptions(languageCode: "zh", keyterms: ["PR", "Supabase"]))
        XCTAssertEqual(text, "我剛剛 push 了一個 PR")

        let captured = try XCTUnwrap(ScriberHTTPStub.requests.first)
        XCTAssertEqual(captured.request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(captured.header("Authorization"), "Bearer \(fakeKey)")
        let fields = Dictionary(multipartFields(captured).map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(fields["model"], "whisper-large-v3-turbo")
        XCTAssertEqual(fields["temperature"], "0")
        XCTAssertEqual(fields["language"], "zh")
        XCTAssertEqual(fields["response_format"], "json")
        XCTAssertEqual(fields["file"], "file:a.wav")
        let prompt = try XCTUnwrap(fields["prompt"])
        XCTAssertTrue(prompt.hasPrefix("以下是台灣繁體中文的逐字稿"))
        XCTAssertTrue(prompt.contains("PR、Supabase"))
        XCTAssertTrue(captured.bodyString.contains("Content-Type: audio/wav"))
    }

    func testWhisperLargeModelID() async throws {
        ScriberHTTPStub.install { _ in .json(["text": "好"]) }
        let stt = GroqWhisperSTT(apiKey: fakeKey, model: .largeV3, session: ScriberHTTPStub.session())
        _ = try await stt.transcribe(audioFile: try makeTempAudioFile(), options: STTOptions(languageCode: "zh"))
        let fields = multipartFields(try XCTUnwrap(ScriberHTTPStub.requests.first))
        XCTAssertEqual(fields.first { $0.name == "model" }?.value, "whisper-large-v3")
    }

    func testWhisperPromptStaysInsideTokenBudget() {
        let terms = (0..<200).map { "專有名詞\($0)" } + ["Kubernetes", "Claude Code"]
        let prompt = WhisperPrompt.build(keyterms: terms, languageCode: "zh")
        XCTAssertLessThanOrEqual(WhisperPrompt.estimateTokens(prompt), WhisperPrompt.tokenBudget)
        XCTAssertLessThan(WhisperPrompt.tokenBudget, 224)
        XCTAssertTrue(prompt.hasSuffix("。"))
        // Shorter terms further down still get in once the long ones stop fitting.
        XCTAssertTrue(prompt.contains("專有名詞0"))
    }

    func testWhisperPromptWithoutTermsIsJustTheLead() {
        XCTAssertEqual(WhisperPrompt.build(keyterms: [], languageCode: "zh"), WhisperPrompt.chineseLead)
        XCTAssertEqual(WhisperPrompt.build(keyterms: ["  ", "\n"], languageCode: nil), WhisperPrompt.chineseLead)
        XCTAssertEqual(WhisperPrompt.build(keyterms: ["Scriber"], languageCode: "en"), "Glossary: Scriber.")
    }

    func testWhisperTokenEstimateIsConservativeForCJK() {
        XCTAssertEqual(WhisperPrompt.estimateTokens("繁體中文"), 12)
        XCTAssertEqual(WhisperPrompt.estimateTokens("Claude Code"), 4)
        XCTAssertGreaterThanOrEqual(WhisperPrompt.estimateTokens(WhisperPrompt.chineseLead), 40)
    }

    func testWhisperHallucinationsAreDiscarded() {
        let prompt = WhisperPrompt.build(keyterms: ["Scriber"], languageCode: "zh")
        XCTAssertEqual(WhisperPrompt.discardHallucination("字幕由Amara.org社区提供", prompt: prompt), "")
        XCTAssertEqual(WhisperPrompt.discardHallucination("請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目", prompt: prompt), "")
        XCTAssertEqual(WhisperPrompt.discardHallucination(prompt, prompt: prompt), "")
        XCTAssertEqual(WhisperPrompt.discardHallucination(WhisperPrompt.chineseLead, prompt: prompt), "")
        // Real short dictations survive.
        XCTAssertEqual(WhisperPrompt.discardHallucination("謝謝", prompt: prompt), "謝謝")
        XCTAssertEqual(WhisperPrompt.discardHallucination("Thank you.", prompt: prompt), "Thank you.")
        XCTAssertEqual(WhisperPrompt.discardHallucination(" 謝謝觀看我的簡報，有問題再跟我說 ", prompt: prompt),
                       "謝謝觀看我的簡報，有問題再跟我說")
    }

    func testWhisperSilenceBecomesEmptyTranscript() async throws {
        ScriberHTTPStub.install { _ in .json(["text": "謝謝觀看"]) }
        let stt = GroqWhisperSTT(apiKey: fakeKey, model: .largeV3Turbo, session: ScriberHTTPStub.session())
        let text = try await stt.transcribe(audioFile: try makeTempAudioFile(), options: STTOptions(languageCode: "zh"))
        XCTAssertEqual(text, "")
    }

    func testRateLimitMessage() async throws {
        ScriberHTTPStub.install { _ in .json(["error": ["message": "Rate limit reached", "type": "tokens"]], status: 429) }
        let stt = GroqWhisperSTT(apiKey: fakeKey, model: .largeV3Turbo, session: ScriberHTTPStub.session())
        do {
            _ = try await stt.transcribe(audioFile: try makeTempAudioFile(), options: STTOptions())
            XCTFail("expected error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.errorDescription, "用量或頻率超過上限，請稍後再試")
        }
    }

    func testTransportErrorsMapToFriendlyMessages() async throws {
        for (code, expected) in [(URLError.Code.notConnectedToInternet, "沒有網路連線，請檢查網路後再試"),
                                 (.timedOut, "連線逾時，請再試一次")] {
            ScriberHTTPStub.install { _ in ScriberHTTPStub.Reply(error: URLError(code)) }
            let stt = GroqWhisperSTT(apiKey: fakeKey, model: .largeV3Turbo, session: ScriberHTTPStub.session())
            do {
                _ = try await stt.transcribe(audioFile: try makeTempAudioFile(), options: STTOptions())
                XCTFail("expected error")
            } catch {
                XCTAssertEqual((error as? ProviderError)?.errorDescription, expected)
            }
        }
    }

    func testDeadlineTimesOutSlowServer() async throws {
        ScriberHTTPStub.install { _ in .json(["text": "late"], delay: 3) }
        let stt = GroqWhisperSTT(apiKey: fakeKey, model: .largeV3Turbo, timeout: 0.2, session: ScriberHTTPStub.session())
        let start = Date()
        do {
            _ = try await stt.transcribe(audioFile: try makeTempAudioFile(), options: STTOptions())
            XCTFail("expected timeout")
        } catch let error as ProviderError {
            XCTAssertTrue(error.isTimeout, "\(error)")
            XCTAssertEqual(error.errorDescription, "連線逾時，請再試一次")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancellationIsHonored() async throws {
        ScriberHTTPStub.install { _ in .json(["text": "late"], delay: 3) }
        let stt = ElevenLabsScribeSTT(apiKey: fakeKey, session: ScriberHTTPStub.session())
        let audio = try makeTempAudioFile()
        let task = Task { try await stt.transcribe(audioFile: audio, options: STTOptions()) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let start = Date()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as ProviderError {
            guard case .cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    // MARK: Key validation

    func testValidateKeyEndpoints() async throws {
        ScriberHTTPStub.install { _ in .json(["data": []]) }
        let session = ScriberHTTPStub.session()
        for kind in APIKeyKind.allCases {
            let message = await STTFactory.validateKey(kind, key: " \(fakeKey)\n", session: session,
                                                       customBaseURL: "https://stt.example.com/v1/")
            XCTAssertNil(message, "\(kind)")
        }
        let requests = ScriberHTTPStub.requests
        XCTAssertEqual(requests.map { $0.request.url?.absoluteString }, [
            "https://api.elevenlabs.io/v1/user",
            "https://api.groq.com/openai/v1/models",
            "https://api.anthropic.com/v1/models",
            "https://stt.example.com/v1/models",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.request.httpMethod == "GET" })
        XCTAssertEqual(requests[0].header("xi-api-key"), fakeKey)
        XCTAssertEqual(requests[1].header("Authorization"), "Bearer \(fakeKey)")
        XCTAssertEqual(requests[2].header("x-api-key"), fakeKey)
        XCTAssertEqual(requests[2].header("anthropic-version"), "2026-10-21")
        XCTAssertEqual(requests[3].header("Authorization"), "Bearer \(fakeKey)")
    }

    func testValidateKeyFailures() async {
        let session = ScriberHTTPStub.session()
        let empty = await STTFactory.validateKey(.groq, key: "   ", session: session)
        XCTAssertEqual(empty, "請先輸入 API key")

        ScriberHTTPStub.install { _ in .json(["error": ["message": "Invalid API Key"]], status: 401) }
        let invalid = await STTFactory.validateKey(.groq, key: fakeKey, session: session)
        XCTAssertEqual(invalid, "API key 無效或沒有權限，請到設定檢查")

        ScriberHTTPStub.install { _ in ScriberHTTPStub.Reply(error: URLError(.notConnectedToInternet)) }
        let offline = await STTFactory.validateKey(.anthropic, key: fakeKey, session: session)
        XCTAssertEqual(offline, "沒有網路連線，請檢查網路後再試")
    }

    func testValidateRestrictedElevenLabsKeyCountsAsValid() async {
        ScriberHTTPStub.install { _ in
            .json(["detail": ["status": "missing_permissions",
                              "message": "The API key you used is missing the permission user_read"]], status: 401)
        }
        let message = await STTFactory.validateKey(.elevenLabs, key: fakeKey, session: ScriberHTTPStub.session())
        XCTAssertNil(message)
    }

    // MARK: Factory + error text

    func testFactoryThrowsMissingKey() {
        let keys = KeychainStore(service: "com.geekaz.Scriber.tests.empty.\(UUID().uuidString)")
        for (kind, keyKind) in [(STTProviderKind.elevenLabsScribe, APIKeyKind.elevenLabs),
                                (.groqWhisperLarge, .groq), (.groqWhisperTurbo, .groq)] {
            XCTAssertThrowsError(try STTFactory.make(kind, keys: keys)) { error in
                guard case ProviderError.missingAPIKey(let missing) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(missing, keyKind)
            }
        }
        XCTAssertEqual(ProviderError.missingAPIKey(.groq).errorDescription, "還沒設定 Groq 的 API key，請到設定填寫")
        XCTAssertEqual(ProviderError.missingAPIKey(.custom).errorDescription, "還沒設定自訂語音辨識的 API key，請到設定填寫")
    }

    func testErrorDescriptions() {
        XCTAssertEqual(ProviderError.http(status: 403, message: "").errorDescription, "API key 無效或沒有權限，請到設定檢查")
        XCTAssertEqual(ProviderError.http(status: 429, message: "").errorDescription, "用量或頻率超過上限，請稍後再試")
        XCTAssertEqual(ProviderError.http(status: 503, message: "").errorDescription, "服務暫時無法使用（503），請稍後再試")
        XCTAssertEqual(ProviderError.http(status: 504, message: "").errorDescription, "服務回應逾時，請再試一次")
        XCTAssertEqual(ProviderError.network("weird-english-detail").errorDescription, "網路連線失敗，請稍後再試")
        XCTAssertEqual(ProviderError.emptyResult.errorDescription, "沒有辨識到內容，請再說一次")
        XCTAssertEqual(ProviderError.cancelled.errorDescription, "已取消")
        XCTAssertEqual(ProviderError.http(status: 401, message: "quota_exceeded: This request exceeds your quota").errorDescription,
                       "帳戶額度不足，請到服務商後台確認")
        XCTAssertEqual(ProviderError.http(status: 400, message: "Your credit balance is too low").errorDescription,
                       "帳戶額度不足，請到服務商後台確認")
        XCTAssertEqual(ProviderError.http(status: 422, message: "").errorDescription, "服務無法處理這次的請求（422）")
        XCTAssertTrue(ProviderError.http(status: 408, message: "").isTimeout)
        XCTAssertFalse(ProviderError.http(status: 500, message: "").isTimeout)
    }

    func testRedaction() {
        let secret = "gsk_abcdefghijklmnopqrstuvwxyz0123456789"
        let scrubbed = ProviderHTTP.redact("Invalid API Key provided: \(secret)", secret: secret)
        XCTAssertFalse(scrubbed.contains(secret))
        XCTAssertFalse(ProviderHTTP.redact("token sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", secret: nil)
            .contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertEqual(ProviderHTTP.redact("Rate limit reached", secret: secret), "Rate limit reached")
    }
}
