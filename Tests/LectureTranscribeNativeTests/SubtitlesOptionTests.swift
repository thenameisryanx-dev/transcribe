import Foundation
import XCTest

@testable import LectureTranscribeNative

final class SubtitlesOptionTests: XCTestCase {
    @MainActor
    func testSubtitlesAndSpeakerLabelsAreExclusive() {
        let viewModel = TranscribeViewModel()
        viewModel.selectedTranscriptionModel = .gpt4oTranscribe
        viewModel.diarizeEnabled = true

        viewModel.subtitlesEnabled = true
        XCTAssertFalse(viewModel.diarizeEnabled)

        viewModel.diarizeEnabled = true
        XCTAssertFalse(viewModel.subtitlesEnabled)
    }

    @MainActor
    func testSubtitlesWorkWithModelsThatCantDiarize() {
        let viewModel = TranscribeViewModel()
        viewModel.selectedTranscriptionModel = .gpt4oMiniTranscribe
        viewModel.subtitlesEnabled = true
        XCTAssertTrue(viewModel.subtitlesEnabled)
    }

    @MainActor
    func testSubtitlesTurnOffContextAndChunkLength() {
        let viewModel = TranscribeViewModel()
        viewModel.selectedTranscriptionModel = .gptTranscribe
        viewModel.subtitlesEnabled = true
        XCTAssertFalse(viewModel.isContextAvailable)
        XCTAssertFalse(viewModel.isKeywordsAvailable)
        XCTAssertFalse(viewModel.isChunkLengthAvailable)
    }

    @MainActor
    func testSubtitlesAllowAutoDetectEvenWithGPTTranscribeSelected() {
        let viewModel = TranscribeViewModel()
        viewModel.selectedTranscriptionModel = .gptTranscribe
        viewModel.spokenLanguage = ""

        // GPT Transcribe alone can't auto-detect, so English is sent.
        viewModel.subtitlesEnabled = false
        XCTAssertFalse(viewModel.isAutoDetectAvailable)
        XCTAssertEqual(viewModel.spokenLanguageCodesForRun, ["en"])
        XCTAssertEqual(viewModel.languageModelDisplayName, "GPT Transcribe")

        // Subtitles run on the diarize model, which can.
        viewModel.subtitlesEnabled = true
        XCTAssertTrue(viewModel.isAutoDetectAvailable)
        XCTAssertEqual(viewModel.spokenLanguageCodesForRun, [])
        XCTAssertEqual(viewModel.effectiveSpokenLanguage, "")
        XCTAssertEqual(viewModel.languageModelDisplayName, TranscribeViewModel.subtitlesModelDisplayName)
    }

    @MainActor
    func testChosenLanguageIsSentInEveryMode() {
        let viewModel = TranscribeViewModel()
        viewModel.selectedTranscriptionModel = .gptTranscribe
        viewModel.spokenLanguage = "it"
        viewModel.subtitlesEnabled = true
        XCTAssertEqual(viewModel.spokenLanguageCodesForRun, ["it"])
        viewModel.subtitlesEnabled = false
        XCTAssertEqual(viewModel.spokenLanguageCodesForRun, ["it"])
    }

    @MainActor
    func testLatestOutputIsSubtitlesFollowsFileExtension() {
        let viewModel = TranscribeViewModel()
        viewModel.latestOutputPath = "/tmp/Episode 3.srt"
        XCTAssertTrue(viewModel.latestOutputIsSubtitles)
        viewModel.latestOutputPath = "/tmp/lecture_20260101_120000.txt"
        XCTAssertFalse(viewModel.latestOutputIsSubtitles)
    }

    func testHistoryEntryWithoutSubtitlesFieldStillDecodes() throws {
        let json = """
        {"id":"11111111-2222-3333-4444-555555555555","startedAt":"2026-01-01T00:00:00Z",
         "inputPath":"/tmp/a.m4a","outputDirectory":"/tmp","diarize":false,"status":"success"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(TranscriptionHistoryEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.subtitles)
    }

    @MainActor
    func testSubtitledCopyIsOnlyMadeWithSubtitles() {
        let viewModel = TranscribeViewModel()
        viewModel.embedSubtitlesEnabled = true
        viewModel.subtitlesEnabled = false
        XCTAssertFalse(viewModel.embedsSubtitlesForRun)
        viewModel.subtitlesEnabled = true
        XCTAssertTrue(viewModel.embedsSubtitlesForRun)
        // Speaker labels switch subtitles off, and the copy with them.
        viewModel.selectedTranscriptionModel = .gpt4oTranscribe
        viewModel.diarizeEnabled = true
        XCTAssertFalse(viewModel.embedsSubtitlesForRun)
    }

    func testARunEmbedsSubtitlesOnlyWithSubtitles() {
        func request(subtitles: Bool, embedSubtitles: Bool) -> RunRequest {
            RunRequest(inputPath: "/tmp/Episode 3.mp4", outputDirectory: "/tmp", options: RunRequest.Options(
                model: .gpt4oTranscribe, diarize: false, subtitles: subtitles, embedSubtitles: embedSubtitles, audioTrack: 0,
                languages: [], contextPrompt: "", consistencyMode: false, chunkLength: .fiveMinutes, keywordsText: ""
            ))
        }
        let both = request(subtitles: true, embedSubtitles: true)
        XCTAssertTrue(both.subtitles)
        XCTAssertTrue(both.embedSubtitles)
        XCTAssertFalse(request(subtitles: true, embedSubtitles: false).embedSubtitles)
        XCTAssertFalse(request(subtitles: false, embedSubtitles: true).embedSubtitles)
    }

    @MainActor
    func testSubtitledCopyEventIsShownAndClearedByTheNextRun() {
        let viewModel = TranscribeViewModel()
        viewModel.apply(event: .subtitledCopy("/tmp/Episode 3.subtitled.mp4"))
        XCTAssertEqual(viewModel.latestSubtitledVideoPath, "/tmp/Episode 3.subtitled.mp4")
        viewModel.clearDraft()
        XCTAssertNil(viewModel.latestSubtitledVideoPath)
    }

    func testHistoryEntryRecordsEmbedSubtitlesAndOldEntriesStillDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let old = """
        {"id":"11111111-2222-3333-4444-555555555555","startedAt":"2026-01-01T00:00:00Z",
         "inputPath":"/tmp/a.mp4","outputDirectory":"/tmp","diarize":false,"status":"success","subtitles":true}
        """
        var entry = try decoder.decode(TranscriptionHistoryEntry.self, from: Data(old.utf8))
        XCTAssertNil(entry.embedSubtitles)

        entry.embedSubtitles = true
        let roundTripped = try decoder.decode(TranscriptionHistoryEntry.self, from: encoder.encode(entry))
        XCTAssertEqual(roundTripped.embedSubtitles, true)
    }
}
