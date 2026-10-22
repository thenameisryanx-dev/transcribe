import Foundation
import XCTest

@testable import LectureTranscribeNative

/// Re-run restores the run's settings, so the backend can reuse the chunks a failed or cancelled run saved.
final class RerunHistoryEntryTests: XCTestCase {
    private func entry(
        model: TranscriptionModel,
        diarize: Bool = false,
        subtitles: Bool = false,
        context: String? = nil,
        keywords: [String]? = nil,
        consistencyMode: Bool? = nil
    ) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            id: UUID(),
            startedAt: Date(),
            finishedAt: Date(),
            // Missing, so the re-run stops before starting the backend.
            inputPath: "/tmp/\(UUID().uuidString)/missing-lecture.m4a",
            outputPath: nil,
            outputDirectory: NSTemporaryDirectory(),
            diarize: diarize,
            status: .failed,
            errorMessage: "Couldn't reach OpenAI.",
            model: model.rawValue,
            context: context,
            keywords: keywords,
            consistencyMode: consistencyMode,
            subtitles: subtitles ? true : nil
        )
    }

    /// Re-run changes remembered preferences; put them back so other tests and runs aren't affected.
    @MainActor
    private func restoringPreferences(of viewModel: TranscribeViewModel, _ body: () -> Void) {
        let outputFolder = viewModel.outputFolderPath
        let model = viewModel.selectedTranscriptionModel
        let consistencyMode = viewModel.consistencyModeEnabled
        let chunkLength = viewModel.chunkLengthPreference
        defer {
            viewModel.outputFolderPath = outputFolder
            viewModel.selectedTranscriptionModel = model
            viewModel.consistencyModeEnabled = consistencyMode
            viewModel.chunkLengthPreference = chunkLength
        }
        body()
    }

    @MainActor
    func testRerunRestoresContextKeywordsAndConsistencyMode() {
        let viewModel = TranscribeViewModel()
        restoringPreferences(of: viewModel) {
            viewModel.contextPrompt = "Today's draft"
            viewModel.keywordsText = "unrelated"
            viewModel.consistencyModeEnabled = false

            viewModel.rerunHistoryEntry(entry(
                model: .gptTranscribe,
                context: "Organic chemistry, week 3",
                keywords: ["SN2", "Grignard reagent"],
                consistencyMode: true
            ))

            XCTAssertEqual(viewModel.contextPrompt, "Organic chemistry, week 3")
            XCTAssertEqual(KeywordList.parse(viewModel.keywordsText), ["SN2", "Grignard reagent"])
            XCTAssertTrue(viewModel.consistencyModeEnabled)
        }
    }

    @MainActor
    func testRerunClearsContextTheRunDidNotSend() {
        let viewModel = TranscribeViewModel()
        restoringPreferences(of: viewModel) {
            viewModel.contextPrompt = "Today's draft"
            viewModel.keywordsText = "unrelated"

            viewModel.rerunHistoryEntry(entry(model: .gpt4oTranscribe))

            XCTAssertEqual(viewModel.contextPrompt, "")
            XCTAssertEqual(viewModel.keywordsText, "")
        }
    }

    @MainActor
    func testRerunOfSpeakerLabelsOrSubtitlesKeepsTheDraftContext() {
        for (diarize, subtitles) in [(true, false), (false, true)] {
            let viewModel = TranscribeViewModel()
            restoringPreferences(of: viewModel) {
                viewModel.contextPrompt = "Today's draft"

                viewModel.rerunHistoryEntry(entry(model: .gpt4oTranscribe, diarize: diarize, subtitles: subtitles))

                XCTAssertEqual(viewModel.contextPrompt, "Today's draft")
            }
        }
    }
}
