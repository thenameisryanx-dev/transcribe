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
    func testSpeakerLabelsFollowTheSelectedModel() {
        let viewModel = TranscribeViewModel()
        let original = viewModel.selectedTranscriptionModel
        defer { viewModel.selectedTranscriptionModel = original }

        viewModel.selectedTranscriptionModel = .gpt4oTranscribe
        XCTAssertTrue(viewModel.isDiarizationAvailable)
        viewModel.selectedTranscriptionModel = .gpt4oMiniTranscribe
        XCTAssertFalse(viewModel.isDiarizationAvailable)
    }

    func testTranscriptionArgumentsSendTheModel() {
        let args = BackendClient.transcriptionArguments(
            inputPath: "/tmp/lecture.m4a",
            outputDirectory: "/tmp",
            diarize: false,
            model: "gpt-4o-mini-transcribe"
        )
        XCTAssertEqual(Array(args.prefix(7)), [
            "run", "--input", "/tmp/lecture.m4a", "--output", "/tmp", "--model", "gpt-4o-mini-transcribe",
        ])
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
