import AppKit
import SwiftUI

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var shouldTerminateAfterLastWindowClosed: (() -> Bool)?
    var bringPrimaryWindowToFront: (() -> Void)?
    /// Asked before the app quits: returns true when it can quit now, or calls `whenReady` once it can.
    var prepareToTerminate: ((_ whenReady: @escaping @Sendable () -> Void) -> Bool)?
    /// The longest a quit waits for `prepareToTerminate`.
    static let terminationWaitLimit: TimeInterval = 30
    private var isWaitingToTerminate = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        shouldTerminateAfterLastWindowClosed?() ?? true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareToTerminate, !isWaitingToTerminate else { return .terminateNow }
        let ready = prepareToTerminate { [weak self] in
            Task { @MainActor in self?.finishTerminating() }
        }
        if ready { return .terminateNow }
        isWaitingToTerminate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationWaitLimit) { [weak self] in
            self?.finishTerminating()
        }
        return .terminateLater
    }

    private func finishTerminating() {
        guard isWaitingToTerminate else { return }
        isWaitingToTerminate = false
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringPrimaryWindowToFront?()
        return true
    }

    @objc private func handleWindowWillClose(_ notification: Notification) {
        terminateIfIdleWithoutPrimaryWindows()
    }

    @objc private func handleDidBecomeActive(_ notification: Notification) {
        bringPrimaryWindowToFront?()
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
    @StateObject private var updateChecker = UpdateChecker()

    private func configureAppLifecycle() {
        appDelegate.shouldTerminateAfterLastWindowClosed = { [viewModel] in
            !viewModel.isRunning
        }
        appDelegate.bringPrimaryWindowToFront = activateAndBringPrimaryWindowToFront
        // Quitting waits for the Listen voice to finish the sentence it's speaking (see `MLXWorkGate`).
        appDelegate.prepareToTerminate = { [viewModel] whenReady in
            viewModel.listen.stopForQuit(whenIdle: whenReady)
        }
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
                .environmentObject(updateChecker)
                // Minimum width is set on RootView's pane, so it doesn't count the sidebar twice.
                .frame(minHeight: 760)
        }
        .defaultSize(width: 1120, height: 812)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    viewModel.selectedPane = .settings
                    Task { await updateChecker.checkNow() }
                }
                .disabled(updateChecker.currentVersion == nil)
            }
            // The app has one window, so ⌘N starts a new transcription instead of opening a window.
            CommandGroup(replacing: .newItem) {
                Button("New Transcription") {
                    viewModel.startNewTranscription()
                    activateAndBringPrimaryWindowToFront()
                }
                .keyboardShortcut("n")
                .disabled(viewModel.isRunning)
            }
            TrackCommands(
                editor: viewModel.trackEditor,
                isShowingTracks: viewModel.selectedPane == .tracks,
                showTracks: {
                    viewModel.selectedPane = .tracks
                    activateAndBringPrimaryWindowToFront()
                }
            )
        }

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
