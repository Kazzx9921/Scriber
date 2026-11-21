import XCTest
@testable import ScriberCore
import ScriberShared

/// The user-defined OpenAI-compatible engine (`STTProviderKind.custom`). Uses the URLProtocol stub
/// from STTProviderTests and the fake keychain from StoresSharedKeychainTests.
final class CustomSTTTests: XCTestCase {
    private let fakeKey = "custom-test-key-not-real-0123456789"

    // MARK: Base URL

    func testBaseURLNormalization() throws {
        let cases: [(raw: String, base: String)] = [
            ("https://api.openai.com/v1", "https://api.openai.com/v1"),
            ("https://api.openai.com/v1/", "https://api.openai.com/v1"),
            ("  https://api.openai.com/v1//\n", "https://api.openai.com/v1"),
            ("https://api.openai.com/v1/audio/transcriptions", "https://api.openai.com/v1"),
            ("https://api.openai.com/v1/audio/transcriptions/", "https://api.openai.com/v1"),
            ("HTTPS://stt.example.com:8443/openai/v1/Audio/Transcriptions", "https://stt.example.com:8443/openai/v1"),
            ("stt.example.com/v1", "https://stt.example.com/v1"),
            ("https://stt.example.com", "https://stt.example.com"),
            ("https://stt.example.com/audio/transcriptions", "https://stt.example.com"),
            ("https://stt.example.com/v1#section", "https://stt.example.com/v1"),
        ]
        for (raw, base) in cases {
            XCTAssertEqual(try CustomSTTEndpoint.parse(raw).baseURL.absoluteString, base, raw)
        }

        let endpoint = try CustomSTTEndpoint.parse("https://api.openai.com/v1/")
        XCTAssertEqual(endpoint.transcriptionsURL.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(endpoint.modelsURL.absoluteString, "https://api.openai.com/v1/models")
        let root = try CustomSTTEndpoint.parse("https://stt.example.com/")
        XCTAssertEqual(root.transcriptionsURL.absoluteString, "https://stt.example.com/audio/transcriptions")
        // A gateway's query (e.g. api-version) is kept for every endpoint.
        let gateway = try CustomSTTEndpoint.parse("https://gw.example.com/v1/audio/transcriptions?api-version=2025-01")
        XCTAssertEqual(gateway.transcriptionsURL.absoluteString,
                       "https://gw.example.com/v1/audio/transcriptions?api-version=2025-01")
        XCTAssertEqual(gateway.modelsURL.absoluteString, "https://gw.example.com/v1/models?api-version=2025-01")
    }

    func testBaseURLRejections() {
        func failure(_ raw: String) -> CustomSTTError? {
            do {
                _ = try CustomSTTEndpoint.parse(raw)
                return nil
            } catch {
                return error as? CustomSTTError
            }
        }
        XCTAssertEqual(failure(""), .missingURL)
        XCTAssertEqual(failure("  \n"), .missingURL)
        XCTAssertEqual(failure("http://stt.example.com/v1"), .insecureURL)
        XCTAssertEqual(failure("HTTP://stt.example.com/v1"), .insecureURL)
        XCTAssertEqual(failure("ftp://stt.example.com/v1"), .invalidURL)
        XCTAssertEqual(failure("https://"), .invalidURL)
        XCTAssertEqual(failure("https:///v1"), .invalidURL)
        XCTAssertEqual(failure("https://user:secret@stt.example.com/v1"), .invalidURL)
        XCTAssertEqual(failure("https://stt example.com/v1"), .invalidURL)

        XCTAssertEqual(CustomSTTError.missingURL.errorDescription, "還沒設定自訂語音辨識的網址，請到設定填寫")
        XCTAssertEqual(CustomSTTError.insecureURL.errorDescription, "自訂語音辨識的網址必須是 https:// 開頭")
        XCTAssertEqual(CustomSTTError.missingModel.errorDescription, "還沒設定自訂語音辨識的模型名稱，請到設定填寫")
    }

    // MARK: Request

    func testRequestShape() async throws {
        ScriberHTTPStub.install { _ in .json(["text": "我剛剛 push 了一個 PR"]) }
        let endpoint = try CustomSTTEndpoint.parse("https://stt.example.com/v1/audio/transcriptions")
        let stt = CustomSTT(endpoint: endpoint, model: "whisper-1", apiKey: fakeKey, session: ScriberHTTPStub.session())
        let text = try await stt.transcribe(audioFile: try makeTempAudioFile("b.wav"),
                                            options: STTOptions(languageCode: "zh-TW", keyterms: ["PR", "Supabase"]))
        XCTAssertEqual(text, "我剛剛 push 了一個 PR")

        let captured = try XCTUnwrap(ScriberHTTPStub.requests.first)
        XCTAssertEqual(ScriberHTTPStub.requests.count, 1)
        XCTAssertEqual(captured.request.httpMethod, "POST")
        XCTAssertEqual(captured.request.url?.absoluteString, "https://stt.example.com/v1/audio/transcriptions")
        XCTAssertEqual(captured.header("Authorization"), "Bearer \(fakeKey)")
        XCTAssertTrue(captured.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let fields = Dictionary(multipartFields(captured).map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(fields["model"], "whisper-1")
        XCTAssertEqual(fields["response_format"], "json")
        XCTAssertEqual(fields["temperature"], "0")
        XCTAssertEqual(fields["language"], "zh")
        XCTAssertEqual(fields["file"], "file:b.wav")
        let prompt = try XCTUnwrap(fields["prompt"])
        XCTAssertEqual(prompt, WhisperPrompt.build(keyterms: ["PR", "Supabase"], languageCode: "zh"))
        XCTAssertTrue(prompt.contains("PR、Supabase"))
        XCTAssertTrue(captured.bodyString.contains("Content-Type: audio/wav"))
    }

    func testSameRequestAsGroqApartFromURLAndModel() throws {
        let options = STTOptions(languageCode: "zh", keyterms: ["鹿野"])
        let prompt = WhisperPrompt.build(keyterms: options.keyterms, languageCode: options.languageCode)
        let custom = CustomSTT(endpoint: try CustomSTTEndpoint.parse("https://stt.example.com/v1"), model: "whisper-large-v3",
                               apiKey: fakeKey, session: ScriberHTTPStub.session())
            .client.makeRequest(audio: Data([1, 2, 3]), filename: "a.m4a", mimeType: "audio/mp4", options: options, prompt: prompt)
        let groq = GroqWhisperSTT(apiKey: fakeKey, model: .largeV3, session: ScriberHTTPStub.session())
            .makeRequest(audio: Data([1, 2, 3]), filename: "a.m4a", mimeType: "audio/mp4", options: options, prompt: prompt)
        XCTAssertEqual(groq.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(custom.url?.absoluteString, "https://stt.example.com/v1/audio/transcriptions")
        XCTAssertEqual(custom.httpMethod, groq.httpMethod)
        XCTAssertEqual(custom.value(forHTTPHeaderField: "Authorization"), groq.value(forHTTPHeaderField: "Authorization"))
        func body(_ request: URLRequest) -> String {
            // Boundaries differ per form; compare everything else.
            let boundary = String(request.value(forHTTPHeaderField: "Content-Type")!.split(separator: "=").last!)
            return String(decoding: request.httpBody!, as: UTF8.self).replacingOccurrences(of: boundary, with: "B")
        }
        XCTAssertEqual(body(custom), body(groq))
    }

    // MARK: Errors

    func testErrorMapping() async throws {
        let endpoint = try CustomSTTEndpoint.parse("https://stt.example.com/v1")
        let stt = CustomSTT(endpoint: endpoint, model: "whisper-1", apiKey: fakeKey, session: ScriberHTTPStub.session())
        let audio = try makeTempAudioFile()

        // 401 whose body echoes the key: scrubbed, generic message.
        ScriberHTTPStub.install { _ in
            .json(["error": ["message": "Incorrect API key provided: \(self.fakeKey)"]], status: 401)
        }
        do {
            _ = try await stt.transcribe(audioFile: audio, options: STTOptions())
            XCTFail("expected error")
        } catch let error as ProviderError {
            guard case .http(let status, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 401)
            XCTAssertFalse(message.contains(fakeKey))
            XCTAssertEqual(error.errorDescription, "API key 無效或沒有權限，請到設定檢查")
        }

        // 404 / 405: the user's URL or model is wrong (not "update the app").
        for status in [404, 405] {
            ScriberHTTPStub.install { _ in .json(["error": ["message": "The model `x` does not exist"]], status: status) }
            do {
                _ = try await stt.transcribe(audioFile: audio, options: STTOptions())
                XCTFail("expected error")
            } catch {
                XCTAssertEqual(error as? CustomSTTError, .endpointNotFound(status: status))
                XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                               "自訂語音辨識找不到這個網址或模型（\(status)），請到設定檢查")
            }
        }

        // Server trouble stays a retryable ProviderError.
        ScriberHTTPStub.install { _ in .json([String: Any](), status: 503) }
        do {
            _ = try await stt.transcribe(audioFile: audio, options: STTOptions())
            XCTFail("expected error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.errorDescription, "服務暫時無法使用（503），請稍後再試")
        }

        // 200 without "text".
        ScriberHTTPStub.install { _ in .json(["transcript": "x"]) }
        do {
            _ = try await stt.transcribe(audioFile: audio, options: STTOptions())
            XCTFail("expected error")
        } catch {
            guard case ProviderError.network(let code)? = error as? ProviderError else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "custom-unexpected-response")
        }
    }

    // MARK: Factory

    func testFactoryReportsWhatIsMissing() throws {
        let keychain = FakeKeychain()
        let keys = KeychainStore(service: "com.geekaz.Scriber.tests.custom", accessGroup: nil,
                                 backend: keychain.backend(groups: ["TEAM.app"]), log: { _ in })
        let session = ScriberHTTPStub.session()
        func failure(_ baseURL: String, _ model: String) -> Error? {
            do {
                _ = try STTFactory.make(.custom, keys: keys, session: session,
                                        custom: CustomSTTConfig(baseURL: baseURL, model: model))
                return nil
            } catch {
                return error
            }
        }
        XCTAssertEqual(failure("", "whisper-1") as? CustomSTTError, .missingURL)
        XCTAssertEqual(failure("http://stt.example.com/v1", "whisper-1") as? CustomSTTError, .insecureURL)
        XCTAssertEqual(failure("https://stt.example.com/v1", "  ") as? CustomSTTError, .missingModel)
        guard case .missingAPIKey(let kind)? = failure("https://stt.example.com/v1", "whisper-1") as? ProviderError else {
            return XCTFail("expected missingAPIKey")
        }
        XCTAssertEqual(kind, .custom)

        keys.setKey(" \(fakeKey)\n", for: .custom)
        let provider = try STTFactory.make(.custom, keys: keys, session: session,
                                           custom: CustomSTTConfig(baseURL: "https://stt.example.com/v1/", model: " whisper-1 "))
        let stt = try XCTUnwrap(provider as? CustomSTT)
        XCTAssertEqual(stt.endpoint.transcriptionsURL.absoluteString, "https://stt.example.com/v1/audio/transcriptions")
        XCTAssertEqual(stt.model, "whisper-1")
        XCTAssertEqual(stt.apiKey, fakeKey)
    }

    // MARK: Key validation

    func testValidateKey() async throws {
        let session = ScriberHTTPStub.session()
        let base = "https://stt.example.com/v1/audio/transcriptions"

        ScriberHTTPStub.install { _ in .json(["data": [["id": "whisper-1"]]]) }
        let ok = await STTFactory.validateKey(.custom, key: fakeKey, session: session, customBaseURL: base)
        XCTAssertNil(ok)
        let captured = try XCTUnwrap(ScriberHTTPStub.requests.first)
        XCTAssertEqual(captured.request.httpMethod, "GET")
        XCTAssertEqual(captured.request.url?.absoluteString, "https://stt.example.com/v1/models")
        XCTAssertEqual(captured.header("Authorization"), "Bearer \(fakeKey)")

        // No model list on this server: cannot verify, assumed OK.
        for status in [404, 405] {
            ScriberHTTPStub.install { _ in .json(["error": "Not Found"], status: status) }
            let message = await STTFactory.validateKey(.custom, key: fakeKey, session: session, customBaseURL: base)
            XCTAssertNil(message, "\(status)")
        }

        ScriberHTTPStub.install { _ in .json(["error": ["message": "invalid key \(self.fakeKey)"]], status: 401) }
        let invalid = await STTFactory.validateKey(.custom, key: fakeKey, session: session, customBaseURL: base)
        XCTAssertEqual(invalid, "API key 無效或沒有權限，請到設定檢查")

        ScriberHTTPStub.install { _ in ScriberHTTPStub.Reply(error: URLError(.cannotFindHost)) }
        let offline = await STTFactory.validateKey(.custom, key: fakeKey, session: session, customBaseURL: base)
        XCTAssertEqual(offline, "沒有網路連線，請檢查網路後再試")

        // Configuration problems are reported without any request.
        ScriberHTTPStub.install { _ in .json(["data": []]) }
        let missing = await STTFactory.validateKey(.custom, key: fakeKey, session: session, customBaseURL: " ")
        XCTAssertEqual(missing, CustomSTTError.missingURL.errorDescription)
        let insecure = await STTFactory.validateKey(.custom, key: fakeKey, session: session,
                                                    customBaseURL: "http://stt.example.com/v1")
        XCTAssertEqual(insecure, CustomSTTError.insecureURL.errorDescription)
        let empty = await STTFactory.validateKey(.custom, key: "  ", session: session, customBaseURL: base)
        XCTAssertEqual(empty, "請先輸入 API key")
        XCTAssertTrue(ScriberHTTPStub.requests.isEmpty)

        for message in [ok, invalid, offline, missing, insecure, empty].compactMap({ $0 }) {
            XCTAssertFalse(message.contains(fakeKey))
        }
    }
}
