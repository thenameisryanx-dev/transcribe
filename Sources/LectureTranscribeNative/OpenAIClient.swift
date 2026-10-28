import Foundation

/// Calls to the OpenAI API made from Swift. `OPENAI_BASE_URL` points it at another server, like the `openai`
/// Python package (the tests use a local stand-in).
struct OpenAIClient: Sendable {
    enum KeyCheck: Equatable, Sendable {
        case ok
        case rejected
        case unreachable
    }

    let baseURL: URL
    let session: URLSession

    init(environment: [String: String] = ProcessInfo.processInfo.environment, session: URLSession = .shared) {
        let configured = (environment["OPENAI_BASE_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = URL(string: configured.isEmpty ? "https://api.openai.com/v1" : configured)
            ?? URL(string: "https://api.openai.com/v1")!
        self.session = session
    }

    /// Asks OpenAI whether `key` works by listing models, which is free. Only a 401 means the key itself was
    /// refused; any other answer from OpenAI (rate limits, server errors) means it accepted the key.
    /// Mirrors `check_api_key_with_openai` in the backend, including its one retry when OpenAI can't be reached.
    func checkKey(_ key: String) async -> KeyCheck {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        for attempt in 1...2 {
            do {
                let (_, response) = try await session.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode == 401 ? .rejected : .ok
            } catch {
                if attempt == 2 || Task.isCancelled { return .unreachable }
            }
        }
        return .unreachable
    }

    // MARK: - Transcription

    /// How long one request may take, and how failed ones are retried. Match the backend's API settings.
    static let requestTimeout: TimeInterval = 20 * 60
    static let maxAttempts = 4
    static let retryBaseSeconds: Double = 2

    /// Sends one audio file to `/audio/transcriptions`, retrying transient failures (timeouts, lost
    /// connections, rate limits, server errors) with exponential backoff like the backend's
    /// `create_transcription_with_retry`. The `openai` Python package also retries twice inside each attempt;
    /// this doesn't. Re-encoding audio OpenAI rejects is left to the caller (see `OpenAIError.isInvalidAudio`).
    func transcribe(
        _ request: TranscriptionRequest,
        audio: URL,
        apiKey: String,
        onRetry: @Sendable (String) -> Void = { _ in },
        sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws -> TranscriptionResult {
        let boundary = "LectureTranscribe-\(UUID().uuidString)"
        let body = try request.multipartBody(audio: audio, boundary: boundary)
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"), timeoutInterval: Self.requestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        for attempt in 1...Self.maxAttempts {
            do {
                let (data, response) = try await session.data(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    throw OpenAIError(status: status, body: data)
                }
                return try TranscriptionResult(json: data)
            } catch {
                guard attempt < Self.maxAttempts, Self.isRetryable(error), !Task.isCancelled else { throw error }
                let delay = Self.retryBaseSeconds * pow(2, Double(attempt - 1))
                onRetry("Transient transcription error on \(audio.lastPathComponent) (attempt \(attempt)/\(Self.maxAttempts)): \(error.localizedDescription). Retrying in \(Int(delay))s...")
                try await sleep(delay)
            }
        }
        throw CancellationError()
    }

    /// Mirrors `is_retryable_transcription_error` in the backend.
    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? OpenAIError {
            if [408, 409, 429, 500, 502, 503, 504].contains(error.status) { return true }
            let message = error.message.lowercased()
            return ["timed out", "timeout", "connection reset", "temporarily unavailable"].contains { message.contains($0) }
        }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
                    .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed].contains(error.code)
        }
        return false
    }
}

/// An error answer from OpenAI.
struct OpenAIError: LocalizedError, Equatable {
    let status: Int
    let message: String
    let code: String?

    init(status: Int, message: String, code: String? = nil) {
        self.status = status
        self.message = message
        self.code = code
    }

    init(status: Int, body: Data) {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        self.init(
            status: status,
            message: error?["message"] as? String ?? String(decoding: body, as: UTF8.self),
            code: error?["code"] as? String
        )
    }

    var errorDescription: String? { "OpenAI returned an error (\(status)): \(message)" }

    /// OpenAI couldn't read the audio; the backend re-encodes the file once and tries again.
    var isInvalidAudio: Bool {
        let message = message.lowercased()
        return status == 400 && message.contains("audio file might be corrupted or unsupported") && message.contains("invalid_value")
    }
}

/// One request to `/audio/transcriptions`. Options a model doesn't take are left out, by the same rules as the
/// backend's `create_transcription_with_retry` (Tests/golden/openai_requests.json records what it sends).
struct TranscriptionRequest: Equatable, Sendable {
    let model: String
    let responseFormat: String
    let chunkingStrategy: String?
    /// The one language GPT-4o and the diarize model take; nil lets them auto-detect.
    let language: String?
    /// GPT Transcribe takes a list of languages instead.
    let languages: [String]
    let prompt: String?
    let keywords: [String]

    static let gptTranscribe = "gpt-transcribe"
    /// Models that take a prompt (the diarize model doesn't).
    static let promptModels: Set<String> = ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    static let keywordModels: Set<String> = ["gpt-transcribe"]

    init(
        model: String,
        responseFormat: String,
        chunkingStrategy: String? = nil,
        languages: [String] = [],
        prompt: String? = nil,
        keywords: [String] = []
    ) {
        self.model = model
        self.responseFormat = responseFormat
        self.chunkingStrategy = chunkingStrategy
        if model == Self.gptTranscribe {
            self.languages = languages
            language = nil
        } else {
            self.languages = []
            language = Self.singleLanguage(languages)
        }
        self.prompt = Self.promptModels.contains(model) ? prompt.flatMap { $0.isEmpty ? nil : $0 } : nil
        self.keywords = Self.keywordModels.contains(model) ? keywords : []
    }

    /// The one `language` to send to models that take only one (`single_language_hint`). Several languages, or a
    /// code that isn't two letters, mean auto-detect, so mixed-language audio isn't forced into one.
    static func singleLanguage(_ languages: [String]?) -> String? {
        guard let languages, languages.count == 1, languages[0].count == 2 else { return nil }
        return languages[0]
    }

    /// The form fields before the file, in the order the `openai` package sends them.
    var formFields: [(name: String, value: String)] {
        var fields: [(String, String)] = [("model", model)]
        if let chunkingStrategy { fields.append(("chunking_strategy", chunkingStrategy)) }
        if let language { fields.append(("language", language)) }
        if let prompt { fields.append(("prompt", prompt)) }
        fields.append(("response_format", responseFormat))
        fields += languages.map { ("languages[]", $0) }
        fields += keywords.map { ("keywords[]", $0) }
        return fields
    }

    /// Content type for the uploaded file, as Python's `mimetypes` names it.
    static func contentType(for audio: URL) -> String {
        switch audio.pathExtension.lowercased() {
        case "m4a": return "audio/mp4a-latm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/x-wav"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    func multipartBody(audio: URL, boundary: String) throws -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for field in formFields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n")
        append("Content-Type: \(Self.contentType(for: audio))\r\n\r\n")
        body.append(try Data(contentsOf: audio))
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}

/// What a transcription request returned: the text, the timed segments the diarize model adds, and the output
/// tokens used (GPT-4o models stop at a limit, which the backend detects from this).
struct TranscriptionResult: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let speaker: String?
        let start: Double?
        let end: Double?
        let text: String
    }

    let text: String
    let segments: [Segment]
    let outputTokens: Int?

    init(text: String, segments: [Segment] = [], outputTokens: Int? = nil) {
        self.text = text
        self.segments = segments
        self.outputTokens = outputTokens
    }

    init(json data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError(status: 200, message: "OpenAI's answer wasn't the expected JSON.")
        }
        self.init(object: object)
    }

    /// From OpenAI's answer, or a diarize result saved in that form (see `ChunkResultStore`).
    init(object: [String: Any]) {
        // Like the backend's `_coerce_optional_float`: a time written as text is read as a number; anything else
        // counts as missing.
        func seconds(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        let segments = (object["segments"] as? [[String: Any]] ?? []).map { segment in
            Segment(
                speaker: (segment["speaker"] as? String) ?? (segment["speaker"] as? NSNumber)?.stringValue,
                start: seconds(segment["start"]),
                end: seconds(segment["end"]),
                text: segment["text"] as? String ?? ""
            )
        }
        let usage = object["usage"] as? [String: Any]
        self.init(
            text: object["text"] as? String ?? "",
            segments: segments,
            outputTokens: (usage?["output_tokens"] as? NSNumber)?.intValue
        )
    }
}
