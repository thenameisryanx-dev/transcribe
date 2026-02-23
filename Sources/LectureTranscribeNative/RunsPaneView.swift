import SwiftUI

private enum RunsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case success = "Success"
    case failed = "Failed"
    case cancelled = "Cancelled"

    var id: String { rawValue }

    func includes(_ status: TranscriptionHistoryEntry.Status) -> Bool {
        switch self {
        case .all:
            return true
        case .running:
            return status == .running
        case .success:
            return status == .success
        case .failed:
            return status == .failed
        case .cancelled:
            return status == .cancelled
        }
    }
}

private enum RunsSortOrder: String, CaseIterable, Identifiable {
    case newestFirst = "Newest"
    case oldestFirst = "Oldest"

    var id: String { rawValue }
}

struct RunsPaneView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel

    @State private var selectedFilter: RunsFilter = .all
    @State private var sortOrder: RunsSortOrder = .newestFirst
    @State private var searchQuery = ""

    private var filteredHistoryEntries: [TranscriptionHistoryEntry] {
        let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = viewModel.historyEntries.filter { entry in
            selectedFilter.includes(entry.status) && matchesSearchQuery(entry, query: normalizedQuery)
        }

        switch sortOrder {
        case .newestFirst:
            return filtered.sorted { $0.startedAt > $1.startedAt }
        case .oldestFirst:
            return filtered.sorted { $0.startedAt < $1.startedAt }
        }
    }

    private var selectedVisibleEntry: TranscriptionHistoryEntry? {
        guard viewModel.selectedHistoryEntryIDs.count == 1 else { return nil }
        guard let selectedID = viewModel.selectedHistoryEntryIDs.first else { return nil }
        return filteredHistoryEntries.first(where: { $0.id == selectedID })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Runs")
                        .font(.headline)

                    Picker("Sort", selection: $sortOrder) {
                        ForEach(RunsSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)

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

                Picker("Status", selection: $selectedFilter) {
                    ForEach(RunsFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

                Divider()

                List(selection: $viewModel.selectedHistoryEntryIDs) {
                    if viewModel.historyEntries.isEmpty {
                        Text("No transcription runs yet.")
                            .foregroundStyle(.secondary)
                    } else if filteredHistoryEntries.isEmpty {
                        Text("No runs match current filters.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredHistoryEntries) { entry in
                            RunRowView(entry: entry)
                                .tag(entry.id)
                        }
                    }
                }
                .searchable(text: $searchQuery, prompt: "Search runs")
                .onDeleteCommand {
                    viewModel.deleteSelectedHistoryEntries()
                }
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
            .onAppear {
                alignSelectionToVisibleEntries()
            }
            .onChange(of: selectedFilter) { _ in
                alignSelectionToVisibleEntries()
            }
            .onChange(of: sortOrder) { _ in
                alignSelectionToVisibleEntries()
            }
            .onChange(of: searchQuery) { _ in
                alignSelectionToVisibleEntries()
            }
            .onChange(of: viewModel.historyEntries) { _ in
                alignSelectionToVisibleEntries()
            }

            Divider()

            if let entry = selectedVisibleEntry {
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
            } else if !viewModel.selectedHistoryEntryIDs.isEmpty, !viewModel.historyEntries.isEmpty {
                VStack(spacing: 10) {
                    Text("Selected Run Hidden")
                        .font(.title2.weight(.semibold))
                    Text("Adjust search/filter options to view this run.")
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

    private func matchesSearchQuery(_ entry: TranscriptionHistoryEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }

        let inputFileName = URL(fileURLWithPath: entry.inputPath).lastPathComponent
        let outputFileName = entry.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let haystack = [
            inputFileName,
            outputFileName,
            entry.status.displayName,
            entry.errorMessage ?? "",
        ]
        .joined(separator: "\n")
        .lowercased()

        return haystack.contains(query)
    }

    private func alignSelectionToVisibleEntries() {
        let visibleIDs = Set(filteredHistoryEntries.map(\.id))
        let selectedVisibleIDs = viewModel.selectedHistoryEntryIDs.intersection(visibleIDs)
        if !selectedVisibleIDs.isEmpty {
            if selectedVisibleIDs != viewModel.selectedHistoryEntryIDs {
                viewModel.selectedHistoryEntryIDs = selectedVisibleIDs
            }
            return
        }

        guard let firstVisibleID = filteredHistoryEntries.first?.id else {
            return
        }
        viewModel.selectedHistoryEntryIDs = [firstVisibleID]
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

    @State private var transcriptPreviewText = ""
    @State private var transcriptPreviewNote = "Transcript preview unavailable."

    private let previewCharacterLimit = 4000

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

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Transcript Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Button("Refresh Preview") {
                            loadTranscriptPreview()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!outputExists)
                    }

                    if transcriptPreviewText.isEmpty {
                        Text(transcriptPreviewNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(transcriptPreviewText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                        if !transcriptPreviewNote.isEmpty {
                            Text(transcriptPreviewNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
        .task(id: entry.id) {
            loadTranscriptPreview()
        }
        .onChange(of: entry.outputPath) { _ in
            loadTranscriptPreview()
        }
    }

    private func loadTranscriptPreview() {
        guard let outputPath = entry.outputPath, !outputPath.isEmpty else {
            transcriptPreviewText = ""
            transcriptPreviewNote = "No transcript file path for this run yet."
            return
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            transcriptPreviewText = ""
            transcriptPreviewNote = "Transcript file is missing or moved."
            return
        }

        do {
            let content = try String(contentsOfFile: outputPath, encoding: .utf8)
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedContent.isEmpty else {
                transcriptPreviewText = ""
                transcriptPreviewNote = "Transcript file is empty."
                return
            }

            if trimmedContent.count > previewCharacterLimit {
                transcriptPreviewText = String(trimmedContent.prefix(previewCharacterLimit))
                transcriptPreviewNote = "Preview truncated to the first \(previewCharacterLimit) characters."
            } else {
                transcriptPreviewText = trimmedContent
                transcriptPreviewNote = ""
            }
        } catch {
            transcriptPreviewText = ""
            transcriptPreviewNote = "Could not load transcript preview: \(error.localizedDescription)"
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
