import SwiftUI

enum NavigationPane: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case tracks = "Tracks"
    case listen = "Listen"
    case runs = "Runs"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .transcribe:
            return "waveform.badge.mic"
        case .tracks:
            return "list.bullet.rectangle"
        case .listen:
            return "speaker.wave.2"
        case .runs:
            return "clock.arrow.circlepath"
        case .settings:
            return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        NavigationSplitView {
            List(NavigationPane.allCases, selection: $viewModel.selectedPane) { pane in
                HStack(spacing: 10) {
                    Image(systemName: pane.systemImage)
                        .frame(width: 16, alignment: .center)
                    Text(pane.rawValue)
                }
                .foregroundStyle(.primary)
                .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 240)
        } detail: {
            Group {
                switch viewModel.selectedPane {
                case .none:
                    TranscribePaneView()
                case .transcribe:
                    TranscribePaneView()
                case .tracks:
                    TracksPaneView(editor: viewModel.trackEditor)
                case .listen:
                    ListenPaneView(model: viewModel.listen)
                case .runs:
                    RunsPaneView()
                case .settings:
                    SettingsPaneView()
                }
            }
            // Grouped Forms report their full content height as their ideal size,
            // which would make the `.contentSize` window grow on its own.
            // The minimum width is the pane's, not the window's: 900 plus the 220pt sidebar makes the 1120pt window.
            // A window-wide minimum made the pane alone 1120 wide while the sidebar was hidden, so showing it again
            // left the toolbar no room mid-slide and macOS pushed the sidebar button into a "»" overflow menu.
            .frame(minWidth: 900, idealWidth: 900, idealHeight: 600)
            .safeAreaInset(edge: .top, spacing: 0) {
                if updateChecker.showsBanner, let update = updateChecker.availableUpdate {
                    UpdateBannerView(update: update)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await updateChecker.checkOnLaunch()
        }
        // Presented from the root so the Transcribe and Settings panes can both use them.
        .sheet(isPresented: $viewModel.showingAPIKeySheet) {
            APIKeySheetView()
                .environmentObject(viewModel)
                .frame(width: 420)
                .padding(20)
        }
        .alert("Lecture Transcribe", isPresented: $viewModel.showingErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }
}

private struct UpdateBannerView: View {
    @EnvironmentObject private var updateChecker: UpdateChecker
    let update: AvailableUpdate

    var body: some View {
        HStack(spacing: 10) {
            switch updateChecker.installState {
            case .idle:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                Text("Lecture Transcribe \(update.version) is available.")
                Spacer()
                Button("Later") {
                    updateChecker.dismissBanner()
                }
                if updateChecker.offersInstall {
                    InstallUpdateButton()
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Download") {
                        updateChecker.openDownload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .downloading(let fraction):
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                Text("Downloading Lecture Transcribe \(update.version)…")
                ProgressView(value: fraction, total: 1)
                    .frame(maxWidth: 200)
                Spacer()
                Button("Cancel") {
                    updateChecker.cancelInstall()
                }
            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text("Installing \(update.version)… Lecture Transcribe will reopen in a moment.")
                Spacer()
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Couldn't install \(update.version). \(message)")
                    .lineLimit(2)
                    .help("To update by hand: download it, quit Lecture Transcribe (⌘Q), then drag the new version into Applications and choose Replace.")
                Spacer()
                Button("Later") {
                    updateChecker.dismissBanner()
                }
                if updateChecker.offersInstall {
                    InstallUpdateButton(title: "Try Again")
                }
                Button("Download") {
                    updateChecker.openDownload()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Starts Install and Relaunch. Disabled during a transcription, since installing quits the app.
private struct InstallUpdateButton: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel
    @EnvironmentObject private var updateChecker: UpdateChecker
    var title = "Install and Relaunch"

    var body: some View {
        Button(title) {
            updateChecker.installUpdate()
        }
        .disabled(viewModel.isRunning || updateChecker.installState.isBusy)
        .help(viewModel.isRunning
            ? "Finish or stop the current transcription first. Installing quits and reopens the app."
            : "Downloads \(updateChecker.availableUpdate?.version ?? "the update"), replaces this copy, and reopens the app.")
    }
}

private struct SettingsPaneView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("OpenAI API Key") {
                    HStack(spacing: 10) {
                        Text(apiKeyStatus)
                            .foregroundStyle(.secondary)
                        Button("Set API Key…") {
                            viewModel.presentAPIKeySheet()
                        }
                        .disabled(viewModel.isRunning)
                    }
                }
            }

            Section {
                Picker("Spoken Language", selection: $viewModel.effectiveSpokenLanguage) {
                    ForEach(SpokenLanguage.all) { language in
                        Text(language.displayName)
                            .tag(language.code)
                            .unselectable(language == .autoDetect && !viewModel.isAutoDetectAvailable)
                    }
                }
                .disabled(viewModel.isRunning)
            } header: {
                Text("Transcription")
            } footer: {
                Text(spokenLanguageFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Output Folder") {
                    Text((viewModel.outputFolderPath as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(viewModel.outputFolderPath)
                }
                HStack {
                    Spacer()
                    Button("Open Output Folder") {
                        viewModel.openOutputFolder()
                    }
                    Button("Change Folder…") {
                        viewModel.browseOutputFolder()
                    }
                }
            } header: {
                Text("Output")
            } footer: {
                Text("Open or change the output folder. Defaults to your Downloads folder.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ListenSettingsSection(model: viewModel.listen)

            Section("Help") {
                LabeledContent {
                    Button("How to Use") {
                        viewModel.requestHowToGuide()
                    }
                } label: {
                    Text("Guided Walkthrough")
                    Text("New to the app? Start the guided walkthrough.")
                }
            }

            Section {
                LabeledContent("Version") {
                    Text(updateChecker.currentVersionText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Text(updateChecker.statusMessage)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if updateChecker.isChecking || updateChecker.installState.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if case .downloading = updateChecker.installState {
                        Button("Cancel") {
                            updateChecker.cancelInstall()
                        }
                    } else if updateChecker.availableUpdate != nil {
                        if updateChecker.offersInstall {
                            InstallUpdateButton()
                        }
                        Button(updateChecker.offersInstall ? "Download" : "Download Update") {
                            updateChecker.openDownload()
                        }
                    }
                    Button("Check for Updates") {
                        Task { await updateChecker.checkNow() }
                    }
                    .disabled(updateChecker.isChecking || updateChecker.installState.isBusy || updateChecker.currentVersion == nil)
                }
            } header: {
                Text("About")
            } footer: {
                Text("Install and Relaunch downloads the new version, replaces this copy, and reopens the app. "
                    + "To update by hand instead, download it, quit Lecture Transcribe (⌘Q), then drag the new version "
                    + "into Applications and choose Replace. Your settings, run history, and API key are kept.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private var spokenLanguageFooter: String {
        if viewModel.isAutoDetectAvailable {
            return "The language spoken in your recordings. \(viewModel.languageModelDisplayName) "
                + "can detect it automatically."
        }
        return "The language spoken in your recordings. \(viewModel.languageModelDisplayName) "
            + "can't auto-detect, so it uses English unless you pick another language."
    }

    private var apiKeyStatus: String {
        let prefix = "API key: "
        let text = viewModel.apiKeyStatusText
        guard text.hasPrefix(prefix) else { return text }
        let status = text.dropFirst(prefix.count)
        return status.prefix(1).uppercased() + status.dropFirst()
    }
}

extension View {
    /// Greys out a picker option. `.disabled` has no effect on items in a macOS menu picker.
    func unselectable(_ isUnselectable: Bool) -> some View {
        selectionDisabled(isUnselectable)
    }
}
