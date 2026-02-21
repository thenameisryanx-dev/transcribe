import SwiftUI

struct RunsPaneView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Runs")
                        .font(.headline)
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        viewModel.deleteSelectedHistoryEntries()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!viewModel.canDeleteSelectedHistoryEntries)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                List(selection: $viewModel.selectedHistoryEntryIDs) {
                    if viewModel.historyEntries.isEmpty {
                        Text("No transcription runs yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.historyEntries) { entry in
                            RunRowView(entry: entry)
                                .tag(entry.id)
                        }
                    }
                }
                .onDeleteCommand {
                    viewModel.deleteSelectedHistoryEntries()
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

            Divider()

            if let entry = viewModel.selectedHistoryEntry {
                RunDetailView(entry: entry)
                    .environmentObject(viewModel)
            } else if viewModel.selectedHistoryEntryCount > 1 {
                VStack(spacing: 10) {
                    Text("Multiple Runs Selected")
                        .font(.title2.weight(.semibold))
                    Text("Select a single run to inspect details.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Text("Runs")
                        .font(.title2.weight(.semibold))
                    Text("Select a run to inspect details.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct RunRowView: View {
    let entry: TranscriptionHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(primaryTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.timestampFormatter.string(from: entry.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(entry.status.displayName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(entry.status.badgeColor.opacity(0.18), in: Capsule())
                .foregroundStyle(entry.status.badgeColor)
        }
        .padding(.vertical, 3)
    }

    private var primaryTitle: String {
        if let outputPath = entry.outputPath, !outputPath.isEmpty {
            return URL(fileURLWithPath: outputPath).lastPathComponent
        }
        return URL(fileURLWithPath: entry.inputPath).lastPathComponent
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct RunDetailView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel

    let entry: TranscriptionHistoryEntry

    private var inputExists: Bool {
        FileManager.default.fileExists(atPath: entry.inputPath)
    }

    private var outputExists: Bool {
        guard let outputPath = entry.outputPath else { return false }
        return FileManager.default.fileExists(atPath: outputPath)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Run Details")
                    .font(.title2.weight(.semibold))

                LabeledContent("Status") {
                    Text(entry.status.displayName)
                        .foregroundStyle(entry.status.badgeColor)
                }

                LabeledContent("Started") {
                    Text(Self.dateTimeFormatter.string(from: entry.startedAt))
                }

                LabeledContent("Finished") {
                    Text(entry.finishedAt.map(Self.dateTimeFormatter.string(from:)) ?? "In progress")
                }

                LabeledContent("Mode") {
                    Text(entry.diarize ? "Diarized" : "Standard")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Input file")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.inputPath)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                    if !inputExists {
                        Text("Original input file is missing. Re-run is disabled.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Output file")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.outputPath ?? "Not available")
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                    if entry.outputPath != nil, !outputExists {
                        Text("Output file is missing or moved.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Output folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.outputDirectory)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                }

                if let errorMessage = entry.errorMessage, !errorMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Error")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 10) {
                    Button("Open Transcript") {
                        viewModel.openHistoryOutput(entry)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!outputExists)

                    Button("Reveal in Finder") {
                        viewModel.revealHistoryOutput(entry)
                    }
                    .buttonStyle(.bordered)

                    Button("Re-run") {
                        viewModel.rerunHistoryEntry(entry)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isRunning || !inputExists)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private extension TranscriptionHistoryEntry.Status {
    var badgeColor: Color {
        switch self {
        case .running:
            return .blue
        case .success:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }
}
