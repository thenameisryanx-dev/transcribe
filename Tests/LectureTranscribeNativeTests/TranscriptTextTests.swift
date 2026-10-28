import Foundation
import XCTest

@testable import LectureTranscribeNative

/// The text functions give the earlier Python backend's answers (Tests/golden/text_functions.json).
final class TranscriptTextTests: XCTestCase {
    static func goldenCases(_ function: String) throws -> [(input: [String: Any], output: Any)] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("golden/text_functions.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let matching = cases.filter { $0["function"] as? String == function }
        XCTAssertFalse(matching.isEmpty, "No reference cases for \(function)")
        return matching.map { ($0["input"] as? [String: Any] ?? [:], $0["output"] as Any) }
    }

    func testSentenceLines() throws {
        for (input, output) in try Self.goldenCases("sentence_lines") {
            let text = input["text"] as! String
            XCTAssertEqual(TranscriptText.sentenceLines(text), output as? [String], text)
        }
    }

    func testTranscriptTail() throws {
        for (input, output) in try Self.goldenCases("transcript_tail") {
            let text = input["text"] as! String, maxChars = input["max_chars"] as! Int
            XCTAssertEqual(TranscriptText.transcriptTail(text, maxChars: maxChars), output as? String, "\(maxChars): \(text.prefix(40))")
        }
    }

    func testStripEchoedTail() throws {
        for (input, output) in try Self.goldenCases("strip_echoed_tail") {
            let expected = output as! [Any]
            let result = TranscriptText.stripEchoedTail(input["text"] as! String, tail: input["tail"] as! String)
            XCTAssertEqual(result.text, expected[0] as? String)
            XCTAssertEqual(result.removed, expected[1] as? Int)
        }
    }

    func testFindRepeatedPassage() throws {
        for (input, output) in try Self.goldenCases("find_repeated_passage") {
            let result = TranscriptText.findRepeatedPassage(input["text"] as! String)
            if let expected = output as? [Any] {
                XCTAssertEqual(result?.length, expected[0] as? Int)
                XCTAssertEqual(result?.opening, expected[1] as? String)
            } else {
                XCTAssertNil(result)
            }
        }
    }

    func testChunkPrompt() throws {
        for (input, output) in try Self.goldenCases("build_chunk_prompt") {
            let prompt = TranscriptText.chunkPrompt(context: input["context"] as? String, previousTail: input["previous_tail"] as? String)
            XCTAssertEqual(prompt, output as? String)
        }
    }

    func testHHMMSS() throws {
        for (input, output) in try Self.goldenCases("hhmmss") {
            XCTAssertEqual(TranscriptText.hhmmss((input["seconds"] as! NSNumber).doubleValue), output as? String)
        }
    }

    func testHeader() throws {
        for (input, output) in try Self.goldenCases("build_transcript_header") {
            let header = TranscriptText.header(
                inputPath: "/lectures/week3.mp4",
                workingInputPath: "/lectures/week3.mp4",
                model: input["model"] as! String,
                responseFormat: input["response_format"] as? String,
                chunkingStrategy: input["chunking_strategy"] as? String,
                localChunkSeconds: input["local_chunk_seconds"] as? Int,
                durationSeconds: (input["duration_seconds"] as? NSNumber)?.doubleValue,
                languages: input["languages"] as? [String] ?? [],
                context: input["context"] as? String,
                keywords: input["keywords"] as? [String] ?? [],
                consistencyMode: input["consistency_mode"] as? Bool,
                chunkWarnings: input["chunk_warnings"] as? [String] ?? []
            )
            XCTAssertEqual(header, output as? String)
        }
    }

    func testKeywordsParseLikeTheBackend() throws {
        for (input, output) in try Self.goldenCases("parse_keywords") {
            let raw = input["raw"] as! String
            if let expected = output as? [String] {
                XCTAssertEqual(KeywordList.parse(raw), expected, raw)
            } else {
                XCTAssertTrue(KeywordList.parse(raw).contains(where: KeywordList.isRejected), raw)
            }
        }
    }

    func testSafeStem() {
        XCTAssertEqual(TranscriptText.safeStem(URL(fileURLWithPath: "/x/Week 3: SN2 (final).mp4")), "Week_3_SN2_final_")
        XCTAssertEqual(TranscriptText.safeStem(URL(fileURLWithPath: "/x/lecture.v2.m4a")), "lecture.v2")
    }
}
