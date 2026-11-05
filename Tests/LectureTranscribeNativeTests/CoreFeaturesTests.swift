import Foundation
import XCTest

@testable import LectureTranscribeNative

/// Features that must keep working (see AGENTS.md). These replace text searches that
/// scripts/regression_check.sh used to run, so they check behavior, not just that a name exists.
final class CoreFeaturesTests: XCTestCase {
    func testSidebarListsEveryPaneInOrder() {
        XCTAssertEqual(
            NavigationPane.allCases.map(\.rawValue),
            ["Transcribe", "Tracks", "Runs", "Settings"]
        )
    }

    @MainActor
    func testViewModelLoadsHistoryAndSavesInterruptedRunsAsCancelled() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let store = TranscriptionHistoryStore(
            historyFileURL: tempDirectory.appendingPathComponent("history.json", isDirectory: false)
        )
        let finished = TranscriptionHistoryEntry(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_706_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_706_000_120),
            inputPath: "/tmp/older.m4a",
            outputPath: "/tmp/older.txt",
            outputDirectory: "/tmp",
            diarize: false,
            status: .success,
            errorMessage: nil
        )
        // Still marked running: the app quit in the middle of this run.
        let interrupted = TranscriptionHistoryEntry(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_706_100_000),
            finishedAt: nil,
            inputPath: "/tmp/newer.m4a",
            outputPath: nil,
            outputDirectory: "/tmp",
            diarize: false,
            status: .running,
            errorMessage: nil
        )
        try store.saveEntries([finished, interrupted])

        let viewModel = TranscribeViewModel(historyStore: store)

        XCTAssertEqual(viewModel.historyEntries.map(\.id), [interrupted.id, finished.id])
        XCTAssertEqual(viewModel.historyEntries.first?.status, .cancelled)
        XCTAssertEqual(viewModel.selectedHistoryEntryIDs, [interrupted.id])

        let saved = try store.loadEntries()
        XCTAssertEqual(saved.first { $0.id == interrupted.id }?.status, .cancelled)
        XCTAssertEqual(saved.first { $0.id == finished.id }?.status, .success)
    }

    @MainActor
    func testOutputFolderDefaultsToDownloads() throws {
        let key = "outputFolderPath"
        let stored = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.set(stored, forKey: key) }

        let downloads = try XCTUnwrap(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        XCTAssertEqual(TranscribeViewModel().outputFolderPath, downloads.path)
    }

    @MainActor
    func testNewUsersStartOnGPTTranscribeWithConsistencyModeAndFiveMinuteChunks() {
        let keys = ["selectedTranscriptionModel", "consistencyMode", "chunkLengthSeconds"]
        let stored = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { zip(keys, stored).forEach { UserDefaults.standard.set($1, forKey: $0) } }

        let viewModel = TranscribeViewModel()
        XCTAssertEqual(viewModel.selectedTranscriptionModel, .gptTranscribe)
        XCTAssertTrue(viewModel.consistencyModeEnabled)
        XCTAssertEqual(viewModel.effectiveChunkLength.seconds, 300)

        let run = RunRequest(inputPath: "/tmp/lecture.m4a", outputDirectory: "/tmp", options: viewModel.runOptions)
        XCTAssertEqual(run.model, .gptTranscribe)
        XCTAssertTrue(run.carryContext)
        XCTAssertEqual(run.chunkSeconds, 300)
    }

    @MainActor
    func testSavedOptionsStillWinOverTheDefaults() {
        let keys = ["selectedTranscriptionModel", "consistencyMode", "chunkLengthSeconds"]
        let stored = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { zip(keys, stored).forEach { UserDefaults.standard.set($1, forKey: $0) } }
        UserDefaults.standard.set("gpt-4o-mini-transcribe", forKey: "selectedTranscriptionModel")
        UserDefaults.standard.set(false, forKey: "consistencyMode")
        UserDefaults.standard.set(600, forKey: "chunkLengthSeconds")

        let viewModel = TranscribeViewModel()
        XCTAssertEqual(viewModel.selectedTranscriptionModel, .gpt4oMiniTranscribe)
        XCTAssertFalse(viewModel.consistencyModeEnabled)
        XCTAssertEqual(viewModel.effectiveChunkLength.seconds, 600)
    }

    @MainActor
    func testSpeakerLabelsFollowTheSelectedModel() {
        let viewModel = TranscribeViewModel()
        let original = viewModel.selectedTranscriptionModel
        defer { viewModel.selectedTranscriptionModel = original }

        viewModel.selectedTranscriptionModel = .gpt4oTranscribe
        XCTAssertTrue(viewModel.isDiarizationAvailable)
        viewModel.selectedTranscriptionModel = .gpt4oMiniTranscribe
        XCTAssertFalse(viewModel.isDiarizationAvailable)
    }

    func testARunUsesTheChosenModel() {
        let request = RunRequest(inputPath: "/tmp/lecture.m4a", outputDirectory: "/tmp", options: RunRequest.Options(
            model: .gpt4oMiniTranscribe, diarize: false, subtitles: false, embedSubtitles: false, audioTrack: 0,
            languages: [], contextPrompt: "", consistencyMode: false, chunkLength: .fiveMinutes, keywordsText: ""
        ))
        XCTAssertEqual(request.model, .gpt4oMiniTranscribe)
        XCTAssertEqual(request.historyEntry().model, "gpt-4o-mini-transcribe")
    }

    @MainActor
    func testHowToGuideOpensOnTheTranscribePaneOnce() {
        let viewModel = TranscribeViewModel()
        viewModel.selectedPane = .runs

        viewModel.requestHowToGuide()

        XCTAssertEqual(viewModel.selectedPane, .transcribe)
        XCTAssertTrue(viewModel.consumeHowToGuideRequestIfNeeded())
        XCTAssertFalse(viewModel.consumeHowToGuideRequestIfNeeded())
    }

    @MainActor
    func testClearDraftAsksFirstThenResetsTheRunButKeepsOptions() {
        let viewModel = TranscribeViewModel()
        viewModel.audioFilePath = "/tmp/lecture.m4a"
        viewModel.contextPrompt = "Cell Biology lecture"
        viewModel.statusText = "Done"
        viewModel.progressValue = 100
        viewModel.logText = "Finished."
        let model = viewModel.selectedTranscriptionModel
        let outputFolder = viewModel.outputFolderPath

        viewModel.requestClearDraft()
        XCTAssertTrue(viewModel.showingClearDraftConfirmation)

        viewModel.clearDraft()
        XCTAssertFalse(viewModel.showingClearDraftConfirmation)
        XCTAssertEqual(viewModel.audioFilePath, "")
        XCTAssertEqual(viewModel.contextPrompt, "")
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(viewModel.progressValue, 0)
        XCTAssertEqual(viewModel.logText, "")
        XCTAssertEqual(viewModel.selectedTranscriptionModel, model)
        XCTAssertEqual(viewModel.outputFolderPath, outputFolder)
        XCTAssertFalse(viewModel.canClearDraft)
    }
}
