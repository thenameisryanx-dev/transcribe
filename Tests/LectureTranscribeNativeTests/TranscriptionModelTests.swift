import XCTest
@testable import LectureTranscribeNative

final class TranscriptionModelTests: XCTestCase {
    func testRawValuesMatchBackendModelIDs() {
        XCTAssertEqual(
            TranscriptionModel.allCases.map(\.rawValue),
            ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
        )
    }

    func testOnlyMiniDisablesDiarization() {
        XCTAssertTrue(TranscriptionModel.gptTranscribe.supportsDiarization)
        XCTAssertTrue(TranscriptionModel.gpt4oTranscribe.supportsDiarization)
        XCTAssertFalse(TranscriptionModel.gpt4oMiniTranscribe.supportsDiarization)
    }

    func testOnlyGPTTranscribeUsesSpokenLanguages() {
        XCTAssertEqual(TranscriptionModel.allCases.filter(\.usesSpokenLanguages), [.gptTranscribe])
    }

    func testSpokenLanguagesParsing() {
        XCTAssertEqual(SpokenLanguages.parse("en"), ["en"])
        XCTAssertEqual(SpokenLanguages.parse(" EN, es  zh,en "), ["en", "es", "zh"])
        XCTAssertEqual(SpokenLanguages.parse(""), [])
        XCTAssertNil(SpokenLanguages.parse("english"))
        XCTAssertNil(SpokenLanguages.parse("en-US"))
    }
}
