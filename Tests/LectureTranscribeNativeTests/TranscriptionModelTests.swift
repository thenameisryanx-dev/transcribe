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

    func testOnlyGPTTranscribeSupportsConsistencyMode() {
        XCTAssertEqual(TranscriptionModel.allCases.filter(\.supportsConsistencyMode), [.gptTranscribe])
    }

    func testOnlyGPTTranscribeRequiresSpokenLanguages() {
        XCTAssertEqual(TranscriptionModel.allCases.filter(\.requiresSpokenLanguages), [.gptTranscribe])
    }

    func testBackendCodes() {
        XCTAssertEqual(SpokenLanguage.backendCodes(for: "", model: .gptTranscribe), ["en"])
        XCTAssertEqual(SpokenLanguage.backendCodes(for: "", model: .gpt4oTranscribe), [])
        XCTAssertEqual(SpokenLanguage.backendCodes(for: "es", model: .gpt4oTranscribe), ["es"])
        XCTAssertEqual(SpokenLanguage.backendCodes(for: "es", model: .gptTranscribe), ["es"])
    }

    func testNormalizedStoredCode() {
        XCTAssertEqual(SpokenLanguage.normalizedCode(nil), "")
        XCTAssertEqual(SpokenLanguage.normalizedCode("es"), "es")
        XCTAssertEqual(SpokenLanguage.normalizedCode(" ES, en"), "es")
        XCTAssertEqual(SpokenLanguage.normalizedCode("english"), "")
    }

    func testLanguageOptionsStartWithAutoDetectAndAreUnique() {
        XCTAssertEqual(SpokenLanguage.all.first, .autoDetect)
        XCTAssertEqual(Set(SpokenLanguage.all.map(\.code)).count, SpokenLanguage.all.count)
    }
}
