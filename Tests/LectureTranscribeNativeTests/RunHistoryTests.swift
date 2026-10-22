import Foundation
import XCTest

@testable import LectureTranscribeNative

/// The rules for the Runs pane's list.
final class RunHistoryTests: XCTestCase {
    private func entry(_ minute: Int, _ status: TranscriptionHistoryEntry.Status = .success) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + minute * 60)),
            finishedAt: status == .running ? nil : Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + minute * 60 + 30)),
            inputPath: "/tmp/week\(minute).m4a",
            outputPath: nil,
            outputDirectory: "/tmp",
            diarize: false,
            status: status,
            errorMessage: nil
        )
    }

    func testLoadingSortsNewestFirstAndClosesInterruptedRuns() {
        let old = entry(1), interrupted = entry(3, .running), middle = entry(2)
        let loaded = RunHistory.loaded([old, interrupted, middle])
        XCTAssertEqual(loaded.entries.map(\.id), [interrupted.id, middle.id, old.id])
        XCTAssertTrue(loaded.changed)
        XCTAssertEqual(loaded.entries[0].status, .cancelled)
        XCTAssertEqual(loaded.entries[0].finishedAt, interrupted.startedAt)
        XCTAssertEqual(loaded.entries[0].errorMessage, "Run interrupted before completion.")
        XCTAssertFalse(RunHistory.loaded([old, middle]).changed)
    }

    func testNewRunsGoFirstAndTheListIsCapped() {
        let full = (0..<RunHistory.maxEntries).map { entry($0) }
        let newest = entry(999, .running)
        let entries = RunHistory.adding(newest, to: full)
        XCTAssertEqual(entries.count, RunHistory.maxEntries)
        XCTAssertEqual(entries.first?.id, newest.id)
        XCTAssertEqual(entries.last?.id, full[RunHistory.maxEntries - 2].id, "The oldest run is dropped")
    }

    func testFinishingARunRecordsItAndMovesItToTheTop() throws {
        let running = entry(1, .running), later = entry(2)
        let finishedAt = Date(timeIntervalSince1970: 1_800_009_999)
        let entries = try XCTUnwrap(RunHistory.finishing(
            running.id,
            in: [later, running],
            status: .success,
            outputPath: "/tmp/week1.txt",
            errorMessage: nil,
            warnings: ["part_002.m4a repeated a passage"],
            log: "Done.",
            at: finishedAt
        ))
        XCTAssertEqual(entries.map(\.id), [running.id, later.id])
        XCTAssertEqual(entries[0].status, .success)
        XCTAssertEqual(entries[0].finishedAt, finishedAt)
        XCTAssertEqual(entries[0].outputPath, "/tmp/week1.txt")
        XCTAssertEqual(entries[0].warnings, ["part_002.m4a repeated a passage"])
        XCTAssertEqual(entries[0].log, "Done.")
        XCTAssertNil(RunHistory.finishing(UUID(), in: entries, status: .failed, outputPath: nil, errorMessage: nil, warnings: [], log: ""))
    }

    func testRunningRunsAreNeverDeleted() {
        let done = entry(1), failed = entry(2, .failed), running = entry(3, .running)
        let deletion = RunHistory.deleting([done.id, running.id], from: [running, failed, done])
        XCTAssertTrue(deletion.deletedAny)
        XCTAssertEqual(deletion.remaining.map(\.id), [running.id, failed.id])
        XCTAssertEqual(deletion.skippedRunning, 1)
        XCTAssertEqual(deletion.keepSelected, running.id)

        let onlyRunning = RunHistory.deleting([running.id], from: [running, failed])
        XCTAssertFalse(onlyRunning.deletedAny)
        XCTAssertEqual(onlyRunning.remaining.count, 2)
    }

    func testSelectionFallsBackToThePreferredRunThenTheNewest() {
        let first = entry(2), second = entry(1)
        let entries = [first, second]
        XCTAssertEqual(RunHistory.selection([second.id, UUID()], in: entries), [second.id])
        XCTAssertEqual(RunHistory.selection([UUID()], in: entries, preferring: second.id), [second.id])
        XCTAssertEqual(RunHistory.selection([], in: entries), [first.id])
        XCTAssertEqual(RunHistory.selection([], in: []), [])
    }

    @MainActor
    func testTheViewModelDeletesSelectedRunsAndSavesTheList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TranscriptionHistoryStore(historyFileURL: directory.appendingPathComponent("history.json"))
        let keep = entry(2), remove = entry(1)
        try store.saveEntries([keep, remove])

        let viewModel = TranscribeViewModel(historyStore: store)
        viewModel.selectedHistoryEntryIDs = [remove.id]
        viewModel.deleteSelectedHistoryEntries()

        XCTAssertEqual(viewModel.historyEntries.map(\.id), [keep.id])
        XCTAssertEqual(viewModel.selectedHistoryEntryIDs, [keep.id])
        XCTAssertEqual(try store.loadEntries().map(\.id), [keep.id])
    }
}
