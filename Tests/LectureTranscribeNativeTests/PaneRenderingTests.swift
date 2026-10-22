import AppKit
import SwiftUI
import XCTest

@testable import LectureTranscribeNative

/// Draws the real app window off-screen and checks what it shows, so the sidebar panes are tested as people see
/// them rather than by searching the source. SwiftUI only exposes the window's title, subtitle and toolbar to
/// accessibility without an assistive app attached, so that is what these tests read.
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
        return TranscribeViewModel(historyStore: store)
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

    /// Every piece of text the window exposes to accessibility.
    @MainActor
    private func visibleText(in window: NSWindow) -> [String] {
        func call(_ object: NSObject, _ name: String) -> Any? {
            let selector = Selector(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        var texts: [String] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 60, let object = element as? NSObject else { return }
            for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = call(object, name) as? String, !text.isEmpty {
                    texts.append(text)
                }
            }
            for child in (call(object, "accessibilityChildren") as? [Any]) ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
        return texts
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

    @MainActor
    func testTranscribeToolbarShowsTheSelectedModel() throws {
        let viewModel = try makeViewModel()
        let original = viewModel.selectedTranscriptionModel
        defer { viewModel.selectedTranscriptionModel = original }
        let window = showWindow(viewModel)
        defer { window.close() }

        for model in TranscriptionModel.allCases {
            viewModel.selectedTranscriptionModel = model
            settle()
            XCTAssertTrue(visibleText(in: window).contains(model.displayName), "The model menu should show \(model.displayName)")
        }
    }
}
