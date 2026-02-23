import Foundation
import XCTest

@testable import LectureTranscribeNative

final class TranscriptionHistoryStoreTests: XCTestCase {
    func testSaveAndLoadEntriesRoundTrip() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let historyFileURL = tempDirectory.appendingPathComponent("history.json", isDirectory: false)
        let store = TranscriptionHistoryStore(historyFileURL: historyFileURL)

        let startedAt = Date(timeIntervalSince1970: 1_706_000_000)
        let finishedAt = Date(timeIntervalSince1970: 1_706_000_120)
        let entry = TranscriptionHistoryEntry(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
            startedAt: startedAt,
            finishedAt: finishedAt,
            inputPath: "/tmp/input.m4a",
            outputPath: "/tmp/output.txt",
            outputDirectory: "/tmp",
            diarize: false,
            status: .success,
            errorMessage: nil
        )

        try store.saveEntries([entry])
        let loaded = try store.loadEntries()
        XCTAssertEqual(loaded, [entry])
    }

    func testLoadEntriesSupportsLegacyRawArrayFormat() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let historyFileURL = tempDirectory.appendingPathComponent("history.json", isDirectory: false)
        let store = TranscriptionHistoryStore(historyFileURL: historyFileURL)

        let entry = TranscriptionHistoryEntry(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") ?? UUID(),
            startedAt: Date(timeIntervalSince1970: 1_706_100_000),
            finishedAt: nil,
            inputPath: "/tmp/lecture.wav",
            outputPath: nil,
            outputDirectory: "/tmp",
            diarize: true,
            status: .running,
            errorMessage: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode([entry])
        try legacyData.write(to: historyFileURL, options: .atomic)

        let loaded = try store.loadEntries()
        XCTAssertEqual(loaded, [entry])
    }
}
