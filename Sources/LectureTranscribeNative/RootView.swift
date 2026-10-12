import SwiftUI

enum NavigationPane: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case runs = "Runs"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .transcribe:
            return "waveform.badge.mic"
        case .runs:
            return "clock.arrow.circlepath"
        case .settings:
            return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel

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
                case .runs:
                    RunsPaneView()
                case .settings:
                    SettingsPaneView()
                }
            }
            // Grouped Forms report their full content height as their ideal size,
            // which would make the `.contentSize` window grow on its own.
            .frame(idealWidth: 600, idealHeight: 600)
        }
        .navigationSplitViewStyle(.balanced)
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

private struct SettingsPaneView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel

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
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private var spokenLanguageFooter: String {
        if viewModel.isAutoDetectAvailable {
            return "The language spoken in your recordings. \(viewModel.selectedTranscriptionModel.displayName) "
                + "can detect it automatically."
        }
        return "The language spoken in your recordings. \(viewModel.selectedTranscriptionModel.displayName) "
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

private extension View {
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
