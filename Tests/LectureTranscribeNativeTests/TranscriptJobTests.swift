import Foundation
import XCTest

@testable import LectureTranscribeNative

/// Answers transcription requests the way the reference runs' fake OpenAI does (Tests/golden/fake_openai.json).
final class ReferenceOpenAI: URLProtocol {
    nonisolated(unsafe) static var answers: [String: Any] = [:]
    /// Chunks whose next request fails once with a 400.
    nonisolated(unsafe) static var failOnce: Set<String> = []
    /// Chunks whose answer takes a second.
    nonisolated(unsafe) static var slow: Set<String> = []
    nonisolated(unsafe) static var sent: [(file: String, prompt: String?)] = []
    static let lock = NSLock()

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReferenceOpenAI.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// The form fields of a multipart body, with the file field's value replaced by its file name.
    private static func fields(_ body: Data) -> [String: String] {
        let text = String(decoding: body, as: UTF8.self)
        var fields: [String: String] = [:]
        for part in text.components(separatedBy: "\r\n--") {
            guard let nameRange = part.range(of: "name=\"") else { continue }
            let name = String(part[nameRange.upperBound...].prefix { $0 != "\"" })
            if let fileRange = part.range(of: "filename=\"") {
                fields[name] = String(part[fileRange.upperBound...].prefix { $0 != "\"" })
            } else if let valueStart = part.range(of: "\r\n\r\n") {
                fields[name] = String(part[valueStart.upperBound...])
            }
        }
        return fields
    }

    override func startLoading() {
        let fields = Self.fields(Self.body(of: request))
        let file = fields["file"] ?? "?"
        let prompt = fields["prompt"]
        let shouldFail = Self.lock.withLock { () -> Bool in
            Self.sent.append((file, prompt))
            return Self.failOnce.remove(file) != nil
        }
        let delay = Self.lock.withLock { Self.slow.contains(file) } ? 1.0 : 0.0
        let status: Int
        let json: [String: Any]
        if shouldFail {
            status = 400
            json = ["error": ["message": "Fake failure for \(file)", "type": "invalid_request_error"]]
        } else {
            status = 200
            let answers = Self.answers
            let n = Int(file.split(separator: "_")[1].prefix { $0.isNumber })! + 1
            let usage = ["output_tokens": answers["output_tokens"] as! Int]
            if fields["response_format"] == "diarized_json" {
                let segments = (answers["segments"] as! [[String: Any]]).map { segment in
                    segment.merging(["text": (segment["text"] as! String).replacingOccurrences(of: "{n}", with: String(n))]) { $1 }
                }
                json = ["text": segments.map { $0["text"] as! String }.joined(separator: " "), "segments": segments, "usage": usage]
            } else {
                var text = (answers["transcript"] as! String).replacingOccurrences(of: "{n}", with: String(n))
                if let prompt, prompt.contains(answers["echo_marker"] as! String) {
                    text = (answers["echo_prefix"] as! String) + text
                }
                if n == answers["looped_chunk"] as! Int {
                    text += " " + (answers["looped"] as! String)
                }
                json = ["text": text, "usage": usage]
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let data = try! JSONSerialization.data(withJSONObject: json)
        // A slow answer arrives later without holding up the others.
        let client = self.client
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Runs done in Swift, checked against the Python backend's reference runs.
final class TranscriptJobTests: XCTestCase {
    private static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("golden")
    private var directory: URL!
    private var recording: URL!
    private var spec: [String: Any] = [:]
    private var events = EventLog()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        spec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.golden.appendingPathComponent("fake_openai.json"))) as? [String: Any])
        ReferenceOpenAI.answers = try XCTUnwrap(spec["answers"] as? [String: Any])
        ReferenceOpenAI.failOnce = []
        ReferenceOpenAI.slow = []
        ReferenceOpenAI.sent = []
        recording = directory.appendingPathComponent("lecture.m4a")
        let arguments = try XCTUnwrap(spec["recording_ffmpeg_arguments"] as? [String]).map {
            $0.replacingOccurrences(of: "<RECORDING>", with: recording.path)
        }
        let tools = try MediaTools.located()
        XCTAssertEqual(try tools.run(tools.ffmpeg, arguments).status, 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func logs() -> [String] {
        events.all.compactMap { if case let .log(message) = $0 { return message } else { return nil } }
    }

    /// A job like the reference runs': diarized in short chunks, unless `singleRequestSeconds` is raised.
    private func job(_ request: RunRequest, maxParallel: Int = 1, singleRequestSeconds: Double? = nil) throws -> TranscriptJob {
        var job = TranscriptJob(
            request: request,
            apiKey: "sk-test",
            openAI: OpenAIClient(environment: ["OPENAI_BASE_URL": "http://openai.test/v1"], session: ReferenceOpenAI.session),
            media: try MediaTools.located(),
            workDirectory: directory.appendingPathComponent("work"),
            maxParallel: maxParallel,
            emit: { [events] event in events.append(event) }
        )
        job.diarizeChunkSeconds = try XCTUnwrap(spec["diarize_chunk_seconds"] as? Int)
        job.diarizeSingleRequestSeconds = try singleRequestSeconds ?? XCTUnwrap((spec["diarize_single_request_seconds"] as? NSNumber)?.doubleValue)
        return job
    }

    private func referenceRun(_ name: String) throws -> [String: Any] {
        let runs = try XCTUnwrap(spec["runs"] as? [String: [String: Any]])
        return try XCTUnwrap(runs[name])
    }

    /// A request with the settings of one of the reference runs.
    private func referenceRequest(_ name: String, input: URL? = nil, embedSubtitles: Bool = false, languages: [String]? = nil) throws -> RunRequest {
        let run = try referenceRun(name)
        var request = RunRequest(
            inputPath: (input ?? recording).path,
            outputDirectory: directory.appendingPathComponent("out").path,
            options: RunRequest.Options(
                model: try XCTUnwrap(TranscriptionModel(rawValue: run["model"] as! String)),
                diarize: run["diarize"] as? Bool ?? false,
                subtitles: run["subtitles"] as? Bool ?? false,
                embedSubtitles: embedSubtitles,
                audioTrack: 0,
                languages: languages ?? run["languages"] as? [String] ?? [],
                contextPrompt: run["context"] as? String ?? "",
                consistencyMode: run["carry_context"] as? Bool ?? false,
                chunkLength: .fiveMinutes,
                keywordsText: (run["keywords"] as? [String] ?? []).joined(separator: ", ")
            )
        )
        request.chunkSeconds = run["chunk_seconds"] as? Int
        return request
    }

    /// The reference run's output file (a transcript or subtitles).
    private func reference(_ name: String) throws -> String {
        let runs = Self.golden.appendingPathComponent("runs")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: runs.path).first { ($0 as NSString).deletingPathExtension == name })
        return try String(contentsOf: runs.appendingPathComponent(file), encoding: .utf8)
    }

    private func assertMatchesReference(_ output: URL, _ name: String) throws {
        let text = try String(contentsOf: output, encoding: .utf8).replacingOccurrences(of: recording.path, with: "<RECORDING>")
        XCTAssertEqual(text, try reference(name), name)
    }

    private func assertMatchesReference(_ name: String) async throws {
        let singleRequestSeconds = (try referenceRun(name)["single_request_seconds"] as? NSNumber)?.doubleValue
        let output = try await job(try referenceRequest(name), singleRequestSeconds: singleRequestSeconds).run()
        try assertMatchesReference(output, name)
    }

    func testPlainTranscriptMatchesTheBackend() async throws {
        try await assertMatchesReference("transcript_gpt4o")
    }

    func testConsistencyModeMatchesTheBackend() async throws {
        try await assertMatchesReference("transcript_consistency_mode")
        XCTAssertTrue(logs().contains { $0.contains("removed 5 word(s) at the start that repeated the previous chunk's excerpt") }, logs().joined(separator: "\n"))
    }

    func testAFailedRunResumesWithOnlyTheMissingChunk() async throws {
        ReferenceOpenAI.failOnce = ["part_001.m4a"]
        let request = try referenceRequest("transcript_gpt4o")
        do {
            _ = try await job(request).run()
            XCTFail("The first run should fail")
        } catch {
            XCTAssertEqual(TranscriptJob.describe(error).message, "OpenAI returned an error (400): Fake failure for part_001.m4a")
        }
        XCTAssertTrue(logs().contains("1 of 3 chunk(s) finished and were saved. Run this again with the same settings to send only the rest."))
        XCTAssertEqual(ReferenceOpenAI.sent.map(\.file), ["part_000.m4a", "part_001.m4a"])

        ReferenceOpenAI.sent = []
        let output = try await job(request).run()
        // part_001 loops, so its check sends it three times.
        XCTAssertEqual(Set(ReferenceOpenAI.sent.map(\.file)), ["part_001.m4a", "part_002.m4a"])
        XCTAssertTrue(logs().contains("Reused 1 of 3 chunk(s) saved from an earlier attempt."))
        let expected = try String(contentsOf: Self.golden.appendingPathComponent("runs/transcript_gpt4o.txt"), encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).replacingOccurrences(of: recording.path, with: "<RECORDING>"), expected)
        let saved = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("work/chunk_results").path)
        XCTAssertEqual(saved, [], "A finished run doesn't need its chunks again")
    }

    func testChunksAlreadySentWhenAnotherFailsAreSaved() async throws {
        ReferenceOpenAI.failOnce = ["part_001.m4a"]
        ReferenceOpenAI.slow = ["part_000.m4a", "part_002.m4a"]
        let request = try referenceRequest("transcript_gpt4o")
        do {
            _ = try await job(request, maxParallel: 4).run()
            XCTFail("The first run should fail")
        } catch {}
        XCTAssertTrue(logs().contains("A chunk failed. Waiting for the 2 chunk(s) already sent so they can be saved..."), logs().joined(separator: "\n"))
        XCTAssertTrue(logs().contains("2 of 3 chunk(s) finished and were saved. Run this again with the same settings to send only the rest."))

        ReferenceOpenAI.sent = []
        ReferenceOpenAI.slow = []
        _ = try await job(request, maxParallel: 4).run()
        XCTAssertEqual(Set(ReferenceOpenAI.sent.map(\.file)), ["part_001.m4a"])
    }

    func testARejectedKeyIsReportedAsAKeyProblem() {
        let described = TranscriptJob.describe(OpenAIError(status: 401, message: "Incorrect API key provided"))
        XCTAssertTrue(described.isAPIKeyProblem)
        XCTAssertEqual(described.message, "OpenAI rejected your API key. Set a valid key in Settings, then try again.")
        XCTAssertFalse(TranscriptJob.describe(OpenAIError(status: 429, message: "x", code: "insufficient_quota")).isAPIKeyProblem)
        XCTAssertEqual(TranscriptJob.describe(URLError(.notConnectedToInternet)).message, "Couldn't reach OpenAI. Check your internet connection, then try again.")
    }

    func testSpeakerLabelsMatchTheBackend() async throws {
        try await assertMatchesReference("speaker_labels")
        XCTAssertEqual(ReferenceOpenAI.sent.map(\.file), ["part_000.m4a", "part_001.m4a", "part_002.m4a"])
    }

    func testShortSpeakerLabelRunsAreOneRequest() async throws {
        try await assertMatchesReference("speaker_labels_single_request")
        XCTAssertEqual(ReferenceOpenAI.sent.map(\.file), ["part_000.m4a"])
    }

    func testSubtitlesMatchTheBackend() async throws {
        let output = try await job(try referenceRequest("subtitles")).run()
        XCTAssertEqual(output.lastPathComponent, "lecture.srt", "Named after the recording, so players find it")
        try assertMatchesReference(output, "subtitles")
        XCTAssertTrue(logs().contains("Wrote 12 subtitle lines."), logs().joined(separator: "\n"))

        // A second run doesn't replace the first one's subtitles.
        let second = try await job(try referenceRequest("subtitles")).run()
        XCTAssertNotEqual(second, output)
        XCTAssertTrue(second.lastPathComponent.hasPrefix("lecture.") && second.lastPathComponent.hasSuffix(".srt"), second.lastPathComponent)
    }

    func testAFailedSubtitleRunResumesWithTheMissingChunks() async throws {
        ReferenceOpenAI.failOnce = ["part_001.m4a"]
        let request = try referenceRequest("subtitles")
        do {
            _ = try await job(request).run()
            XCTFail("The first run should fail")
        } catch {}
        XCTAssertTrue(logs().contains("1 of 3 chunk(s) finished and were saved. Run this again with the same settings to send only the rest."), logs().joined(separator: "\n"))

        ReferenceOpenAI.sent = []
        let output = try await job(request).run()
        XCTAssertEqual(ReferenceOpenAI.sent.map(\.file), ["part_001.m4a", "part_002.m4a"])
        XCTAssertTrue(logs().contains("Reused 1 of 3 chunk(s) saved from an earlier attempt."))
        try assertMatchesReference(output, "subtitles")
    }

    /// A short video with a picture, one audio track and a subtitle track of its own, in each container that can
    /// hold a subtitled copy.
    private func makeVideo(_ fileExtension: String) throws -> URL {
        let tools = try MediaTools.located()
        let video = directory.appendingPathComponent("clip.\(fileExtension)")
        let srt = directory.appendingPathComponent("own.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nOriginal\n".utf8).write(to: srt)
        let result = try tools.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=3",
            "-f", "lavfi", "-i", "sine=duration=3",
            "-i", srt.path,
            "-map", "0", "-map", "1", "-map", "2",
            "-c:v", "libx264", "-c:a", "aac", "-c:s", fileExtension == "mkv" ? "srt" : "mov_text",
            video.path,
        ])
        XCTAssertEqual(result.status, 0, result.errors)
        return video
    }

    private func subtitleTracks(_ video: URL) throws -> [String] {
        let tools = try MediaTools.located()
        let result = try tools.run(tools.ffprobe, [
            "-v", "error", "-select_streams", "s",
            "-show_entries", "stream=codec_name,codec_tag_string:stream_tags=language:stream_disposition=default",
            "-of", "csv=p=0", video.path,
        ])
        return result.output.split(separator: "\n").map(String.init)
    }

    func testSubtitledCopiesHoldOnlyTheNewSubtitles() async throws {
        let expected = [
            "mp4": ["mov_text,tx3g,1,fra"],
            "mov": ["mov_text,tx3g,1,fra"],
            "mkv": ["subrip,[0][0][0][0],1,fre"],
        ]
        for (fileExtension, tracks) in expected.sorted(by: { $0.key < $1.key }) {
            let video = try makeVideo(fileExtension)
            events = EventLog()
            _ = try await job(try referenceRequest("subtitles", input: video, embedSubtitles: true, languages: ["fr"])).run()
            let copy = directory.appendingPathComponent("out/clip.subtitled.\(fileExtension)")
            XCTAssertEqual(try subtitleTracks(copy), tracks, fileExtension)
            let reported = events.all.compactMap { if case let .subtitledCopy(path) = $0 { return path } else { return nil } }
            XCTAssertEqual(reported, [copy.resolvingSymlinksInPath().path], fileExtension)
            XCTAssertTrue(logs().contains("Saved a copy of the video with subtitles: \(copy.path)"), logs().joined(separator: "\n"))
        }
    }

    func testAudioFilesGetNoSubtitledCopy() async throws {
        _ = try await job(try referenceRequest("subtitles", embedSubtitles: true)).run()
        XCTAssertTrue(logs().contains("Subtitles can only be built into .m4v, .mkv, .mov, .mp4 videos, so no copy of this .m4a was saved."), logs().joined(separator: "\n"))
        XCTAssertFalse(events.all.contains { if case .subtitledCopy = $0 { return true } else { return false } })
    }

    func testOnlyQTAFilesStillRunInTheBackend() throws {
        var request = try referenceRequest("transcript_gpt4o")
        XCTAssertTrue(TranscriptJob.handles(request))
        request.subtitles = true
        XCTAssertTrue(TranscriptJob.handles(request))
        request.subtitles = false
        request.diarize = true
        XCTAssertTrue(TranscriptJob.handles(request))
        request.inputPath = "/tmp/recording.qta"
        XCTAssertFalse(TranscriptJob.handles(request))
    }
}

/// Events a job emits, collected from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BackendStreamEvent] = []
    func append(_ event: BackendStreamEvent) { lock.withLock { events.append(event) } }
    var all: [BackendStreamEvent] { lock.withLock { events } }
}
