import Foundation
import XCTest

@testable import LectureTranscribeNative

/// The Swift subtitle functions give the Python backend's answers (Tests/golden/text_functions.json).
final class SubtitleTextTests: XCTestCase {
    private func segments(_ input: [String: Any]) -> [TranscriptionResult.Segment] {
        TranscriptionResult(object: ["text": "", "segments": input["segments"] as! [[String: Any]]]).segments
    }

    func testWrap() throws {
        for (input, output) in try TranscriptTextTests.goldenCases("wrap_subtitle_text") {
            let text = input["text"] as! String
            XCTAssertEqual(SubtitleText.wrap(text), output as? [String], text)
        }
    }

    func testPieces() throws {
        for (input, output) in try TranscriptTextTests.goldenCases("subtitle_pieces") {
            let text = input["text"] as! String
            XCTAssertEqual(SubtitleText.pieces(text), output as? [String], String(text.prefix(40)))
        }
    }

    func testTimestamp() throws {
        for (input, output) in try TranscriptTextTests.goldenCases("srt_timestamp") {
            let seconds = (input["seconds"] as! NSNumber).doubleValue
            XCTAssertEqual(SubtitleText.timestamp(seconds), output as? String, "\(seconds)")
        }
    }

    func testSRT() throws {
        for (input, output) in try TranscriptTextTests.goldenCases("format_srt(subtitle_cues)") {
            let cues = SubtitleText.cues(
                segments(input),
                offsetSeconds: (input["offset_seconds"] as! NSNumber).doubleValue,
                chunk: input["chunk"] as! Int
            )
            XCTAssertEqual(SubtitleText.srt(cues), output as? String, "\(input["name"] ?? "") at \(input["offset_seconds"] ?? "")")
        }
    }

    func testDiarizedLines() throws {
        for (input, output) in try TranscriptTextTests.goldenCases("format_diarized_lines") {
            XCTAssertEqual(SubtitleText.diarizedLines(segments(input)), output as? [String], "\(input["name"] ?? "")")
        }
    }

    func testSubtitleLanguageTags() {
        XCTAssertEqual(MediaTools.subtitleTrackLanguage("fr", containerExtension: "mp4"), "fra")
        XCTAssertEqual(MediaTools.subtitleTrackLanguage("fr", containerExtension: "MKV"), "fre")
        XCTAssertEqual(MediaTools.subtitleTrackLanguage("ger", containerExtension: "mov"), "ger")
        XCTAssertNil(MediaTools.subtitleTrackLanguage("zz", containerExtension: "mp4"))
        XCTAssertNil(MediaTools.subtitleTrackLanguage(nil, containerExtension: "mp4"))
    }

    func testSavedDiarizeResultsReadBackTheSame() {
        let response = TranscriptionResult(text: "Hi. Hello.", segments: [
            .init(speaker: "A", start: 0, end: 1.5, text: "Hi."),
            .init(speaker: nil, start: 1.5, end: 3, text: "Hello."),
        ])
        let saved = PythonJSON.encode([
            "text": response.text,
            "segments": response.segments.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end, "text": $0.text] as [String: Any?] },
        ] as [String: Any?])
        XCTAssertEqual(
            saved,
            #"{"segments": [{"end": 1.5, "speaker": "A", "start": 0.0, "text": "Hi."}, {"end": 3.0, "speaker": null, "start": 1.5, "text": "Hello."}], "text": "Hi. Hello."}"#,
            "Written as Python's json.dumps writes it"
        )
        let object = try! JSONSerialization.jsonObject(with: Data(saved.utf8)) as! [String: Any]
        XCTAssertEqual(TranscriptionResult(object: object), response)
    }
}
