import Foundation
import ScriberShared

/// OpenAI-compatible `POST …/audio/transcriptions` (multipart upload, `{"text": …}` back).
/// Shared by Groq Whisper and the user-defined custom engine so both send the same request.
///
/// Docs: https://platform.openai.com/docs/api-reference/audio/createTranscription
///       https://console.groq.com/docs/speech-to-text
struct OpenAITranscription: Sendable {
    /// Full URL of the transcription endpoint.
    let endpoint: URL
    /// Sent as `model`.
    let model: String
    let apiKey: String
    let timeout: TimeInterval
    let session: URLSession
    /// Prefix of the diagnostic code for an unexpected response body ("groq", "custom").
    let vendor: String

    func transcribe(audioFile: URL, options: STTOptions) async throws -> String {
        let audio = try AudioFile.load(audioFile)
        let prompt = WhisperPrompt.build(keyterms: options.keyterms, languageCode: options.languageCode)
        let request = makeRequest(audio: audio, filename: audioFile.lastPathComponent,
                                  mimeType: MultipartForm.audioMimeType(for: audioFile),
                                  options: options, prompt: prompt)
        let data = try await ProviderHTTP.withDeadline(seconds: timeout) { [session, apiKey] in
            try await ProviderHTTP.send(request, session: session, secret: apiKey)
        }
        let json = try ProviderHTTP.decodeJSONObject(data)
        guard let text = json["text"] as? String else {
            throw ProviderError.network("\(vendor)-unexpected-response")
        }
        return WhisperPrompt.discardHallucination(text, prompt: prompt)
    }

    func makeRequest(audio: Data, filename: String, mimeType: String,
                     options: STTOptions, prompt: String) -> URLRequest {
        var form = MultipartForm()
        form.addField("model", model)
        form.addField("response_format", "json")
        form.addField("temperature", "0")
        if let language = ProviderHTTP.isoLanguage(options.languageCode) {
            form.addField("language", language)
        }
        if !prompt.isEmpty {
            form.addField("prompt", prompt)
        }
        form.addFile("file", filename: filename.isEmpty ? "audio.m4a" : filename, mimeType: mimeType, data: audio)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.finalized()
        return request
    }
}
