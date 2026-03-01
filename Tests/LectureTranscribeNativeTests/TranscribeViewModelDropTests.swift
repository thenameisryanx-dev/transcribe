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
}
