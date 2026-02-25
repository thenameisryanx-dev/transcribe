import SwiftUI
import UniformTypeIdentifiers

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
    @State private var isGlobalInputDropTargeted = false

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
        .navigationSplitViewStyle(.balanced)
        .onDrop(of: [.fileURL], isTargeted: $isGlobalInputDropTargeted, perform: handleFileDrop)
        .overlay(alignment: .top) {
            if isGlobalInputDropTargeted {
                Text("Drop audio/video file to use as input")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    @discardableResult
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let droppedURL = Self.resolveDroppedFileURL(from: item) else { return }
            Task { @MainActor in
                viewModel.selectDroppedInputFile(droppedURL)
            }
        }
        return true
    }

    nonisolated private static func resolveDroppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL, url.isFileURL {
            return url.standardizedFileURL
        }

        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                return url.standardizedFileURL
            }
        }

        if let value = item as? String,
           let url = URL(string: value),
           url.isFileURL
        {
            return url.standardizedFileURL
        }

        return nil
    }
}

private struct SettingsPaneView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Text("Help and app-level preferences.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Open or change the output folder. Defaults to your Downloads folder.")
                        .foregroundStyle(.secondary)
                    Text(viewModel.outputFolderPath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 10) {
                        Button("Change Folder…") {
                            viewModel.browseOutputFolder()
                        }
                        .buttonStyle(.bordered)
                        Button("Open Output Folder") {
                            viewModel.openOutputFolder()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            GroupBox("Help") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New to the app? Start the guided walkthrough.")
                        .foregroundStyle(.secondary)
                    Button("How to Use") {
                        viewModel.requestHowToGuide()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}
