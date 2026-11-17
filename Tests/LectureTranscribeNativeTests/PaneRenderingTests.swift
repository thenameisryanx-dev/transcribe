import AppKit
import SwiftUI
import XCTest

@testable import LectureTranscribeNative

/// Draws the real app window off-screen and checks what it shows, so the sidebar panes are tested as people see
/// them rather than by searching the source. They read the window's title and subtitle, which
/// SwiftUI sets for the pane on screen.
final class PaneRenderingTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// A view model with its own run history, so tests never read or change the real one.
    @MainActor
    private func makeViewModel(history: [TranscriptionHistoryEntry] = []) throws -> TranscribeViewModel {
        let store = TranscriptionHistoryStore(historyFileURL: tempDirectory.appendingPathComponent("history.json"))
        try store.saveEntries(history)
        return TranscribeViewModel(historyStore: store, listen: makeTestListenModel(directory: tempDirectory))
    }

    @MainActor
    private func showWindow(_ viewModel: TranscribeViewModel) -> NSWindow {
        _ = NSApplication.shared
        let root = RootView()
            .environmentObject(viewModel)
            .environmentObject(UpdateChecker(bundle: Bundle(for: Self.self)))
        let window = NSWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: 1120, height: 760),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        settle()
        return window
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    private func entry(_ input: String, status: TranscriptionHistoryEntry.Status) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            id: UUID(),
            startedAt: Date(),
            finishedAt: Date(),
            inputPath: input,
            outputPath: nil,
            outputDirectory: "/tmp",
            diarize: false,
            status: status,
            errorMessage: nil
        )
    }

    @MainActor
    func testEverySidebarPaneOpens() throws {
        let viewModel = try makeViewModel()
        let window = showWindow(viewModel)
        defer { window.close() }

        for pane in NavigationPane.allCases {
            viewModel.selectedPane = pane
            settle()
            XCTAssertEqual(window.title, pane.rawValue, "Selecting \(pane.rawValue) should show its pane")
        }
    }

    @MainActor
    func testRunsPaneListsSavedRuns() throws {
        let viewModel = try makeViewModel(history: [
            entry("/tmp/week1.m4a", status: .success),
            entry("/tmp/week2.m4a", status: .failed),
        ])
        let window = showWindow(viewModel)
        defer { window.close() }

        viewModel.selectedPane = .runs
        settle()
        XCTAssertEqual(window.title, "Runs")
        XCTAssertEqual(window.subtitle, "2 of 2")
    }

    /// The Hide Sidebar button is the system one, in the sidebar's own part of the toolbar (before the separator
    /// that tracks the sidebar's edge), as Apple's guidelines place it. When the sidebar collapses, macOS moves it
    /// beside the pane title.
    @MainActor
    func testSystemSidebarButtonIsInTheSidebarOnEveryPane() throws {
        let viewModel = try makeViewModel()
        let window = showWindow(viewModel)
        defer { window.close() }

        for pane in NavigationPane.allCases {
            viewModel.selectedPane = pane
            settle()
            let identifiers = (window.toolbar?.items ?? []).map(\.itemIdentifier.rawValue)
            let button = identifiers.firstIndex(of: "com.apple.SwiftUI.navigationSplitView.toggleSidebar")
            let separator = identifiers.firstIndex { $0.hasPrefix("com.apple.SwiftUI.splitViewSeparator") }
            XCTAssertNotNil(button, "\(pane.rawValue) should show the system sidebar button")
            XCTAssertNotNil(separator, "\(pane.rawValue) should give the sidebar its own part of the toolbar")
            if let button, let separator {
                XCTAssertLessThan(button, separator, "\(pane.rawValue) should show the sidebar button over the sidebar")
            }
        }
    }
}

/// The toolbar's model menu names the model the run will use. (macOS 26 doesn't expose toolbar text to tests,
/// so this checks the label the menu is given rather than reading the drawn toolbar.)
final class ModelMenuTests: XCTestCase {
    func testTheMenuNamesTheSelectedModel() {
        for model in TranscriptionModel.allCases {
            XCTAssertEqual(ModelSelectionMenu.title(selectedModel: model, fixedModelName: nil), model.displayName)
        }
    }

    @MainActor
    func testSubtitlesNameTheDiarizeModelAndLockTheMenu() {
        let viewModel = TranscribeViewModel()
        XCTAssertNil(viewModel.modelMenuFixedName)
        viewModel.subtitlesEnabled = true
        XCTAssertEqual(viewModel.modelMenuFixedName, "GPT-4o Transcribe Diarize")
        XCTAssertEqual(
            ModelSelectionMenu.title(selectedModel: .gptTranscribe, fixedModelName: viewModel.modelMenuFixedName),
            "GPT-4o Transcribe Diarize"
        )
    }
}

/// The Listen pane's empty-text hint says what opens and what happens next, before and after the voice is downloaded.
final class ListenPlaceholderTests: XCTestCase {
    func testTheHintFollowsTheVoiceDownload() {
        let downloaded = ListenPaneView.placeholderDetail(voiceDownloaded: true)
        let notYet = ListenPaneView.placeholderDetail(voiceDownloaded: false)
        for hint in [downloaded, notYet] {
            XCTAssertTrue(hint.hasPrefix("PDFs, Word documents, web pages saved as HTML, and text or Markdown files all work. You can also drop a file here. "), hint)
        }
        XCTAssertTrue(downloaded.hasSuffix("Press Play to make the speech on this Mac; then it's read aloud with each word highlighted as it's spoken. Click any word to jump to it."), downloaded)
        XCTAssertTrue(notYet.hasSuffix("Once the voice below is downloaded, it's read aloud with each word highlighted as it's spoken."), notYet)
    }
}
