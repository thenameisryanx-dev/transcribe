import Foundation
import XCTest

@testable import LectureTranscribeNative

/// Answers each request with the next scripted reply, and records the requests.
final class ScriptedOpenAI: URLProtocol {
    enum Reply {
        case status(Int, String)
        case failure(URLError.Code)
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedOpenAI.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let reply = Self.replies.isEmpty ? .status(200, #"{"text": ""}"#) : Self.replies.removeFirst()
        switch reply {
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .status(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// The Swift OpenAI transcription client, checked against what the Python backend sends today.
final class OpenAIClientTests: XCTestCase {
    private var directory: URL!
    private var audio: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audio = directory.appendingPathComponent("part_000.m4a")
        try Data("not really audio".utf8).write(to: audio)
        ScriptedOpenAI.replies = []
        ScriptedOpenAI.requests = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func client() -> OpenAIClient {
        OpenAIClient(environment: ["OPENAI_BASE_URL": "http://openai.test/v1"], session: ScriptedOpenAI.session)
    }

    /// Splits a multipart body into (name, value) fields; the file's value is "filename|content type".
    private func fields(in body: Data, boundary: String) -> [[String]] {
        let text = String(decoding: body, as: UTF8.self)
        return text.components(separatedBy: "--\(boundary)").dropFirst().compactMap { part -> [String]? in
            guard part.hasPrefix("\r\n") else { return nil }
            let pieces = part.dropFirst(2).components(separatedBy: "\r\n\r\n")
            let head = pieces[0]
            let value = pieces.dropFirst().joined(separator: "\r\n\r\n")
            let name = head.components(separatedBy: "name=\"")[1].components(separatedBy: "\"")[0]
            if head.contains("filename=\"") {
                let filename = head.components(separatedBy: "filename=\"")[1].components(separatedBy: "\"")[0]
                let type = head.components(separatedBy: "Content-Type: ")[1]
                return [name, "\(filename)|\(type)"]
            }
            // Each value ends with the line break before the next boundary (one Character in Swift).
            return [name, value.hasSuffix("\r\n") ? String(value.dropLast()) : value]
        }
    }

    func testRequestsMatchWhatTheBackendSends() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("golden/openai_requests.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let input = try XCTUnwrap(item["input"] as? [String: Any])
            let sent = try XCTUnwrap(item["request"] as? [String: Any])
            let request = TranscriptionRequest(
                model: try XCTUnwrap(input["model"] as? String),
                responseFormat: try XCTUnwrap(input["response_format"] as? String),
                chunkingStrategy: input["chunking_strategy"] as? String,
                languages: input["languages"] as? [String] ?? [],
                prompt: input["prompt"] as? String,
                keywords: input["keywords"] as? [String] ?? []
            )
            let expected = try XCTUnwrap(sent["fields"] as? [[Any]]).map { field -> [String] in
                if let file = field[1] as? [String: String] {
                    return [field[0] as! String, "\(file["filename"]!)|\(file["content_type"]!)"]
                }
                return [field[0] as! String, field[1] as! String]
            }
            let body = try request.multipartBody(audio: audio, boundary: "BOUNDARY")
            XCTAssertEqual(fields(in: body, boundary: "BOUNDARY"), expected, "\(input)")
            XCTAssertEqual(sent["path"] as? String, "/v1/audio/transcriptions")
        }
    }

    func testTheRequestGoesToTheTranscriptionEndpointWithTheKey() async throws {
        ScriptedOpenAI.replies = [.status(200, #"{"text": "Hello.", "usage": {"output_tokens": 7}}"#)]
        let result = try await client().transcribe(
            TranscriptionRequest(model: "gpt-4o-transcribe", responseFormat: "json"),
            audio: audio,
            apiKey: "sk-test"
        )
        XCTAssertEqual(result, TranscriptionResult(text: "Hello.", outputTokens: 7))
        let request = try XCTUnwrap(ScriptedOpenAI.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://openai.test/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
    }

    func testDiarizedAnswersKeepTheirTimedSegments() throws {
        let json = #"{"text": "Hi. Out.", "segments": [{"speaker": "A", "start": 0.4, "end": 3.9, "text": "Hi."}, {"speaker": "B", "start": 4, "end": 4.3, "text": "Out."}, {"text": "untimed"}]}"#
        let result = try TranscriptionResult(json: Data(json.utf8))
        XCTAssertEqual(result.segments, [
            .init(speaker: "A", start: 0.4, end: 3.9, text: "Hi."),
            .init(speaker: "B", start: 4, end: 4.3, text: "Out."),
            .init(speaker: nil, start: nil, end: nil, text: "untimed"),
        ])
        XCTAssertNil(result.outputTokens)
    }

    func testTransientFailuresAreRetriedWithGrowingWaits() async throws {
        ScriptedOpenAI.replies = [
            .status(500, #"{"error": {"message": "server error"}}"#),
            .failure(.timedOut),
            .status(429, #"{"error": {"message": "slow down", "code": "rate_limit_exceeded"}}"#),
            .status(200, #"{"text": "Finally."}"#),
        ]
        let waits = WaitLog()
        let result = try await client().transcribe(
            TranscriptionRequest(model: "gpt-4o-transcribe", responseFormat: "json"),
            audio: audio,
            apiKey: "sk-test",
            sleep: { await waits.add($0) }
        )
        XCTAssertEqual(result.text, "Finally.")
        let recorded = await waits.seconds
        XCTAssertEqual(recorded, [2, 4, 8])
        XCTAssertEqual(ScriptedOpenAI.requests.count, 4)
    }

    func testItGivesUpAfterFourAttempts() async {
        ScriptedOpenAI.replies = Array(repeating: .status(503, #"{"error": {"message": "unavailable"}}"#), count: 5)
        do {
            _ = try await client().transcribe(
                TranscriptionRequest(model: "gpt-4o-transcribe", responseFormat: "json"),
                audio: audio,
                apiKey: "sk-test",
                sleep: { _ in }
            )
            XCTFail("Should have given up")
        } catch {
            XCTAssertEqual(error as? OpenAIError, OpenAIError(status: 503, message: "unavailable"))
        }
        XCTAssertEqual(ScriptedOpenAI.requests.count, 4)
    }

    func testRequestErrorsAreNotRetried() async {
        let message = "Audio file might be corrupted or unsupported (invalid_value)"
        ScriptedOpenAI.replies = [.status(400, #"{"error": {"message": "\#(message)", "code": "invalid_value"}}"#)]
        do {
            _ = try await client().transcribe(
                TranscriptionRequest(model: "gpt-4o-transcribe", responseFormat: "json"),
                audio: audio,
                apiKey: "sk-test",
                sleep: { _ in }
            )
            XCTFail("Should have failed")
        } catch {
            let error = error as? OpenAIError
            XCTAssertEqual(error?.status, 400)
            XCTAssertEqual(error?.code, "invalid_value")
            XCTAssertEqual(error?.isInvalidAudio, true)
            XCTAssertEqual(error?.errorDescription, "OpenAI returned an error (400): \(message)")
        }
        XCTAssertEqual(ScriptedOpenAI.requests.count, 1)
    }
}

private actor WaitLog {
    var seconds: [Double] = []
    func add(_ value: Double) { seconds.append(value) }
}
