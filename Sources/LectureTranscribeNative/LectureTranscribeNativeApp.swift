import AppKit
import SwiftUI

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var shouldTerminateAfterLastWindowClosed: (() -> Bool)?
    var bringPrimaryWindowToFront: (() -> Void)?
    private var windowWillCloseObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?

    override init() {
        super.init()
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.terminateIfIdleWithoutPrimaryWindows()
        }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringPrimaryWindowToFront?()
        }
    }

    deinit {
        if let windowWillCloseObserver {
            NotificationCenter.default.removeObserver(windowWillCloseObserver)
        }
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        shouldTerminateAfterLastWindowClosed?() ?? true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringPrimaryWindowToFront?()
        return true
    }

    private func terminateIfIdleWithoutPrimaryWindows() {
        guard shouldTerminateAfterLastWindowClosed?() ?? true else {
            return
        }

        DispatchQueue.main.async {
            let hasVisiblePrimaryWindow = NSApplication.shared.windows.contains { window in
                window.isVisible && window.canBecomeMain
            }

            if !hasVisiblePrimaryWindow {
                NSApplication.shared.terminate(nil)
            }
        }
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
        appDelegate.bringPrimaryWindowToFront = activateAndBringPrimaryWindowToFront
    }

    private func activateAndBringPrimaryWindowToFront() {
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.async {
            let primaryWindows = NSApp.windows.filter { $0.canBecomeMain }
            guard !primaryWindows.isEmpty else {
                return
            }

            for window in primaryWindows where window.isMiniaturized {
                window.deminiaturize(nil)
            }

            for window in primaryWindows {
                window.orderFrontRegardless()
            }

            if let candidateWindow = primaryWindows.first(where: \.isVisible) ?? primaryWindows.first {
                candidateWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    var body: some Scene {
        let _ = configureAppLifecycle()

        WindowGroup("Lecture Transcribe") {
            RootView()
                .environmentObject(viewModel)
                .frame(minWidth: 1120, minHeight: 760)
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
                    activateAndBringPrimaryWindowToFront()
                }
                Button("Quit Lecture Transcribe") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
        }
    }
}
