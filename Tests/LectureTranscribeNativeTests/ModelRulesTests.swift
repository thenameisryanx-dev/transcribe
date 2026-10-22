import Foundation
import XCTest

@testable import LectureTranscribeNative

/// The app and the Python backend each state what every model can do. Both are checked against
/// Tests/model_rules.json (test_backend.py checks the Python side), so the two can't drift apart.
final class ModelRulesTests: XCTestCase {
    private struct Rules: Decodable {
        let speaker_labels: Bool
        let consistency_mode: Bool
        let keywords: Bool
        let context_prompt: Bool
        let needs_spoken_languages: Bool
    }

    private func loadRules() throws -> [String: Rules] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("model_rules.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let models = object.filter { !$0.key.hasPrefix("_") }
        let data = try JSONSerialization.data(withJSONObject: models)
        return try JSONDecoder().decode([String: Rules].self, from: data)
    }

    func testAppOffersExactlyTheModelsInTheRules() throws {
        XCTAssertEqual(Set(TranscriptionModel.allCases.map(\.rawValue)), Set(try loadRules().keys))
    }

    func testEachModelsOptionsMatchTheRules() throws {
        let rules = try loadRules()
        for model in TranscriptionModel.allCases {
            let expected = try XCTUnwrap(rules[model.rawValue], model.rawValue)
            XCTAssertEqual(model.supportsDiarization, expected.speaker_labels, "\(model.rawValue) speaker labels")
            XCTAssertEqual(model.supportsConsistencyMode, expected.consistency_mode, "\(model.rawValue) consistency mode")
            XCTAssertEqual(model.supportsKeywords, expected.keywords, "\(model.rawValue) keywords")
            XCTAssertEqual(model.requiresSpokenLanguages, expected.needs_spoken_languages, "\(model.rawValue) spoken languages")
            // The app offers the context prompt with every model (it's only off for speaker labels and subtitles).
            XCTAssertTrue(expected.context_prompt, "\(model.rawValue) context prompt")
        }
    }
}
