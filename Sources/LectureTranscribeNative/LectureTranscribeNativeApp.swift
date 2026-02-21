import AppKit
import SwiftUI

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var shouldTerminateAfterLastWindowClosed: (() -> Bool)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        shouldTerminateAfterLastWindowClosed?() ?? true
    }
}

@main
struct LectureTranscribeNativeApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var viewModel = TranscribeViewModel()

    private func configureAppLifecycle() {
        appDelegate.shouldTerminateAfterLastWindowClosed = { [viewModel] in
            !viewModel.isRunning
        }
    }

    var body: some Scene {
        let _ = configureAppLifecycle()

        WindowGroup("Lecture Transcribe") {
            RootView()
                .environmentObject(viewModel)
                .frame(minWidth: 920, minHeight: 640)
        }
        .windowResizability(.contentSize)

        MenuBarExtra(
            viewModel.isRunning ? viewModel.progressLabel : "LT",
            systemImage: "waveform.and.mic"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.isRunning ? "Transcription in progress" : "Lecture Transcribe")
                    .font(.headline)
                Text("\(viewModel.progressLabel) • \(viewModel.statusText)")
                    .foregroundStyle(.secondary)
                Divider()
                Button("Open Lecture Transcribe") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Quit Lecture Transcribe") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
        }
    }
}
