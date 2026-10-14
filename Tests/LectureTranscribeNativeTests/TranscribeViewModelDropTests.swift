import Foundation
import XCTest

@testable import LectureTranscribeNative

final class TranscribeViewModelDropTests: XCTestCase {
    @MainActor
    func testLoadDroppedAudioFileSetsAudioPathForExistingFile() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let droppedFileURL = tempDirectory.appendingPathComponent("sample.m4a", isDirectory: false)
        try Data("audio".utf8).write(to: droppedFileURL, options: .atomic)

        let viewModel = TranscribeViewModel()
        viewModel.loadDroppedAudioFile(droppedFileURL)

        XCTAssertEqual(viewModel.audioFilePath, droppedFileURL.path)
        XCTAssertFalse(viewModel.showingErrorAlert)
    }

    @MainActor
    func testLoadDroppedAudioFileRejectsDirectoryDrop() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let viewModel = TranscribeViewModel()
        let existingPath = "/tmp/existing-audio.m4a"
        viewModel.audioFilePath = existingPath

        viewModel.loadDroppedAudioFile(tempDirectory)

        XCTAssertEqual(viewModel.audioFilePath, existingPath)
        XCTAssertTrue(viewModel.showingErrorAlert)
        XCTAssertEqual(viewModel.errorMessage, "Drop an audio/video file, not a folder.")
    }

    @MainActor
    func testChoosingDifferentRecordingResetsPreviousRunResult() {
        let viewModel = TranscribeViewModel()
        viewModel.audioFilePath = "/tmp/first-lecture.m4a"
        viewModel.statusText = "Done"
        viewModel.progressValue = 100
        viewModel.latestOutputPath = "/tmp/first-lecture.txt"
        viewModel.canOpenOutputFolder = true

        viewModel.audioFilePath = "/tmp/second-lecture.m4a"

        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(viewModel.progressValue, 0)
        XCTAssertNil(viewModel.latestOutputPath)
        XCTAssertFalse(viewModel.canOpenOutputFolder)
        XCTAssertFalse(viewModel.hasTranscribedCurrentRecording)
        XCTAssertTrue(viewModel.canStart)
    }

    @MainActor
    func testChoosingSameRecordingAgainResetsFinishedRun() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }
        let recordingURL = tempDirectory.appendingPathComponent("lecture.m4a", isDirectory: false)
        try Data("audio".utf8).write(to: recordingURL, options: .atomic)

        let viewModel = TranscribeViewModel()
        viewModel.audioFilePath = recordingURL.path
        viewModel.contextPrompt = "Cell Biology"
        viewModel.apply(event: .done("/tmp/lecture.txt"))
        XCTAssertTrue(viewModel.hasTranscribedCurrentRecording)

        viewModel.loadDroppedAudioFile(recordingURL)

        XCTAssertEqual(viewModel.audioFilePath, recordingURL.path)
        XCTAssertFalse(viewModel.hasTranscribedCurrentRecording)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(viewModel.progressValue, 0)
        XCTAssertEqual(viewModel.contextPrompt, "Cell Biology")
        XCTAssertTrue(viewModel.canStart)
    }

    @MainActor
    func testSelectingAnotherModelAfterFinishedRunResetsForNextRun() {
        let viewModel = TranscribeViewModel()
        let originalModel = viewModel.selectedTranscriptionModel
        defer { viewModel.selectedTranscriptionModel = originalModel }
        viewModel.selectedTranscriptionModel = .gpt4oTranscribe
        viewModel.audioFilePath = "/tmp/finished-lecture.m4a"
        viewModel.contextPrompt = "Cell Biology"
        viewModel.apply(event: .done("/tmp/finished-lecture.txt"))
        XCTAssertTrue(viewModel.hasTranscribedCurrentRecording)

        viewModel.selectedTranscriptionModel = .gpt4oMiniTranscribe

        XCTAssertEqual(viewModel.audioFilePath, "/tmp/finished-lecture.m4a")
        XCTAssertFalse(viewModel.hasTranscribedCurrentRecording)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(viewModel.progressValue, 0)
        XCTAssertEqual(viewModel.contextPrompt, "Cell Biology")
        XCTAssertTrue(viewModel.canStart)
    }

    @MainActor
    func testStartNewTranscriptionClearsDraftAndShowsTranscribePane() {
        let viewModel = TranscribeViewModel()
        viewModel.selectedPane = .runs
        viewModel.audioFilePath = "/tmp/finished-lecture.m4a"
        viewModel.statusText = "Done"
        viewModel.progressValue = 100
        viewModel.logText = "Done. Wrote: /tmp/finished-lecture.txt"

        viewModel.startNewTranscription()

        XCTAssertEqual(viewModel.selectedPane, .transcribe)
        XCTAssertEqual(viewModel.audioFilePath, "")
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(viewModel.progressValue, 0)
        XCTAssertEqual(viewModel.logText, "")
        XCTAssertFalse(viewModel.showingClearDraftConfirmation)
    }
}
