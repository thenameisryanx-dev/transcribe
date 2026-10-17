import SwiftUI

enum NavigationPane: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case tracks = "Tracks"
    case runs = "Runs"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .transcribe:
            return "waveform.badge.mic"
        case .tracks:
            return "list.bullet.rectangle"
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
                case .runs:
                    RunsPaneView()
                case .settings:
                    SettingsPaneView()
                }
            }
            // Grouped Forms report their full content height as their ideal size,
            // which would make the `.contentSize` window grow on its own.
            .frame(idealWidth: 600, idealHeight: 600)
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
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            Text("Lecture Transcribe \(update.version) is available.")
            Spacer()
            Button("Later") {
                updateChecker.dismissBanner()
            }
            Button("Download") {
                updateChecker.openDownload()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
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
                    Text(updateChecker.lastCheckMessage)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if updateChecker.availableUpdate != nil {
                        Button("Download Update") {
                            updateChecker.openDownload()
                        }
                    }
                    Button("Check for Updates") {
                        Task { await updateChecker.checkNow() }
                    }
                    .disabled(updateChecker.isChecking || updateChecker.currentVersion == nil)
                }
            } header: {
                Text("About")
            } footer: {
                Text("To update, download the new version, drag it into Applications, and choose Replace. "
                    + "Your settings, run history, and API key are kept.")
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
    @ViewBuilder
    func unselectable(_ isUnselectable: Bool) -> some View {
        if #available(macOS 14.0, *) {
            selectionDisabled(isUnselectable)
        } else {
            disabled(isUnselectable)
        }
    }
}
