import SwiftUI

private enum RunsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case success = "Success"
    case warnings = "Warnings"
    case failed = "Failed"
    case cancelled = "Cancelled"

    var id: String { rawValue }

    func includes(_ entry: TranscriptionHistoryEntry) -> Bool {
        let status = entry.status
        switch self {
        case .all:
            return true
        case .running:
            return status == .running
        case .success:
            return status == .success
        case .warnings:
            return entry.hasWarnings
        case .failed:
            return status == .failed
        case .cancelled:
            return status == .cancelled
        }
    }
}

struct RunsPaneView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel

    @State private var selectedFilter: RunsFilter = .all
    @State private var sortOrder = [KeyPathComparator(\TranscriptionHistoryEntry.startedAt, order: .reverse)]
    @State private var searchQuery = ""
    @AppStorage("showsRunInspector") private var showsInspector = true

    private var filteredHistoryEntries: [TranscriptionHistoryEntry] {
        let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return viewModel.historyEntries
            .filter { entry in
                selectedFilter.includes(entry) && matchesSearchQuery(entry, query: normalizedQuery)
            }
            .sorted(using: sortOrder)
    }

    private var selectedVisibleEntry: TranscriptionHistoryEntry? {
        guard viewModel.selectedHistoryEntryIDs.count == 1 else { return nil }
        guard let selectedID = viewModel.selectedHistoryEntryIDs.first else { return nil }
        return filteredHistoryEntries.first(where: { $0.id == selectedID })
    }

    var body: some View {
        runsTable
            .overlay {
                if viewModel.historyEntries.isEmpty {
                    EmptyStateView(
                        title: "No Runs Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: "Transcriptions you start will appear here."
                    )
                } else if filteredHistoryEntries.isEmpty {
                    EmptyStateView(
                        title: "No Matching Runs",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: "No runs match current filters."
                    )
                }
            }
            .modifier(RunInspector(isPresented: $showsInspector) {
                inspectorContent
            })
            .navigationTitle("Runs")
            .navigationSubtitle("\(filteredHistoryEntries.count) of \(viewModel.historyEntries.count)")
            .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search runs")
            .toolbar { runsToolbar }
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
    }

    private var runsTable: some View {
        Table(filteredHistoryEntries, selection: $viewModel.selectedHistoryEntryIDs, sortOrder: $sortOrder) {
            TableColumn("Recording", value: \.recordingName) { entry in
                Text(entry.recordingName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.inputPath)
            }
            .width(min: 180, ideal: 320)

            TableColumn("Status", value: \.statusName) { entry in
                Label(entry.statusName, systemImage: entry.statusImage)
                    .foregroundStyle(entry.statusColor)
                    .help(entry.warnings?.joined(separator: "\n") ?? "")
            }
            .width(min: 90, ideal: 110, max: 140)

            TableColumn("Model", value: \.modelName)
                .width(min: 100, ideal: 150, max: 200)

            TableColumn("Started", value: \.startedAt) { entry in
                Text(entry.startedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .monospacedDigit()
            }
            .width(min: 130, ideal: 170, max: 200)
        }
        .contextMenu(forSelectionType: TranscriptionHistoryEntry.ID.self) { ids in
            if ids.count == 1, let entry = viewModel.historyEntries.first(where: { ids.contains($0.id) }) {
                Button("Open Transcript", systemImage: "doc.text") {
                    viewModel.openHistoryOutput(entry)
                }
                Button("Reveal in Finder", systemImage: "folder") {
                    viewModel.revealHistoryOutput(entry)
                }
                Button("Re-run", systemImage: "arrow.clockwise") {
                    viewModel.rerunHistoryEntry(entry)
                }
                .disabled(viewModel.isRunning || !FileManager.default.fileExists(atPath: entry.inputPath))
                Divider()
            }
            if !ids.isEmpty {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    viewModel.selectedHistoryEntryIDs = ids
                    viewModel.deleteSelectedHistoryEntries()
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let entry = viewModel.historyEntries.first(where: { ids.contains($0.id) }) else {
                return
            }
            viewModel.openHistoryOutput(entry)
        }
        .onDeleteCommand {
            viewModel.deleteSelectedHistoryEntries()
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let entry = selectedVisibleEntry {
            RunDetailView(entry: entry)
                .environmentObject(viewModel)
        } else if viewModel.selectedHistoryEntryCount > 1 {
            EmptyStateView(
                title: "Multiple Runs Selected",
                systemImage: "square.stack",
                description: "Select a single run to inspect details."
            )
        } else if !viewModel.selectedHistoryEntryIDs.isEmpty, !viewModel.historyEntries.isEmpty {
            EmptyStateView(
                title: "Selected Run Hidden",
                systemImage: "line.3.horizontal.decrease.circle",
                description: "Adjust search/filter options to view this run."
            )
        } else {
            EmptyStateView(
                title: "No Selection",
                systemImage: "sidebar.trailing",
                description: "Select a run to inspect details."
            )
        }
    }

    @ToolbarContentBuilder
    private var runsToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Status", selection: $selectedFilter) {
                    ForEach(RunsFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(
                    "Filter",
                    systemImage: selectedFilter == .all
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .help("Filter by status")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let entry = selectedVisibleEntry {
                    viewModel.rerunHistoryEntry(entry)
                }
            } label: {
                Label("Re-run", systemImage: "arrow.clockwise")
            }
            .help("Re-run this transcription")
            .disabled(
                selectedVisibleEntry.map { viewModel.isRunning || !FileManager.default.fileExists(atPath: $0.inputPath) } ?? true
            )

            Button {
                if let entry = selectedVisibleEntry {
                    viewModel.revealHistoryOutput(entry)
                }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Reveal in Finder")
            .disabled(selectedVisibleEntry == nil)

            Button {
                if let entry = selectedVisibleEntry {
                    viewModel.openHistoryOutput(entry)
                }
            } label: {
                Label("Open Transcript", systemImage: "doc.text")
            }
            .help("Open Transcript")
            .disabled(
                selectedVisibleEntry.flatMap(\.outputPath).map { !FileManager.default.fileExists(atPath: $0) } ?? true
            )

            Button(role: .destructive) {
                viewModel.deleteSelectedHistoryEntries()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete selected runs")
            .disabled(!viewModel.canDeleteSelectedHistoryEntries)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(showsInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    private func matchesSearchQuery(_ entry: TranscriptionHistoryEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }

        let inputFileName = URL(fileURLWithPath: entry.inputPath).lastPathComponent
        let outputFileName = entry.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let haystack = [
            inputFileName,
            outputFileName,
            entry.statusName,
            entry.errorMessage ?? "",
            (entry.warnings ?? []).joined(separator: "\n"),
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

/// Shows run details in a system inspector (macOS 14+), or a trailing column on older systems.
private struct RunInspector<InspectorContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder var inspector: () -> InspectorContent

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .inspector(isPresented: $isPresented) {
                    inspector()
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
                }
        } else {
            HStack(spacing: 0) {
                content
                if isPresented {
                    Divider()
                    inspector()
                        .frame(width: 320)
                }
            }
        }
    }
}

private extension TranscriptionHistoryEntry {
    var recordingName: String {
        URL(fileURLWithPath: inputPath).lastPathComponent
    }

    var statusName: String {
        hasWarnings && status == .success ? "Warnings" : status.displayName
    }

    var statusImage: String {
        hasWarnings && status == .success ? "exclamationmark.triangle.fill" : status.systemImage
    }

    var statusColor: Color {
        hasWarnings && status == .success ? .orange : status.badgeColor
    }

    var modelName: String {
        guard let model else { return "—" }
        return TranscriptionModel(rawValue: model)?.displayName ?? model
    }
}

private struct RunDetailView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel

    let entry: TranscriptionHistoryEntry

    @State private var transcriptPreviewText = ""
    @State private var transcriptPreviewNote = "Transcript preview unavailable."
    @State private var showsFullLog = false

    private let previewCharacterLimit = 4000
    private static let logPreviewLineLimit = 12

    private var inputExists: Bool {
        FileManager.default.fileExists(atPath: entry.inputPath)
    }

    // A running entry has no saved log yet, so show the live one.
    private var runLog: String? {
        entry.status == .running ? viewModel.logText : entry.log
    }

    private var outputExists: Bool {
        guard let outputPath = entry.outputPath else { return false }
        return FileManager.default.fileExists(atPath: outputPath)
    }

    var body: some View {
        Form {
            Section("Run Details") {
                LabeledContent("Status") {
                    Label(entry.statusName, systemImage: entry.statusImage)
                        .foregroundStyle(entry.statusColor)
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

                if let rawModel = entry.model {
                    LabeledContent("Model") {
                        Text(TranscriptionModel(rawValue: rawModel)?.displayName ?? rawModel)
                    }
                }

                if let context = entry.context {
                    LabeledContent("Context") {
                        Text(context)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let chunkSeconds = entry.chunkSeconds {
                    LabeledContent("Chunk Length") {
                        Text("\(chunkSeconds / 60) min")
                    }
                }

                if entry.consistencyMode == true {
                    LabeledContent("Consistency Mode") {
                        Text("On")
                    }
                }
            }

            Section("Files") {
                pathRow(
                    "Input file",
                    path: entry.inputPath,
                    warning: inputExists ? nil : "Original input file is missing. Re-run is disabled."
                )
                pathRow(
                    "Output file",
                    path: entry.outputPath ?? "Not available",
                    warning: entry.outputPath != nil && !outputExists ? "Output file is missing or moved." : nil
                )
                pathRow("Output folder", path: entry.outputDirectory, warning: nil)
            }

            if let errorMessage = entry.errorMessage, !errorMessage.isEmpty {
                Section("Error") {
                    Label {
                        Text(errorMessage)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
            }

            if let warnings = entry.warnings, !warnings.isEmpty {
                Section {
                    ForEach(warnings, id: \.self) { warning in
                        Label {
                            Text(warning)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Warnings")
                } footer: {
                    Text("The run finished, but these parts of the transcript may be missing or wrong.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // The inspector already scrolls, so the log isn't its own scroll view here
            // (nested same-direction scroll views hand off scrolling at their edges).
            // Show the latest lines inline and the whole log in a sheet.
            Section {
                if let log = runLog, !log.isEmpty {
                    let lines = log.components(separatedBy: "\n")
                    Text(lines.suffix(Self.logPreviewLineLimit).joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No log was saved for this run. Logs are saved for runs from this version on.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Run Log")
                    Spacer()
                    Button("Show Full Log…") {
                        showsFullLog = true
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(runLog?.isEmpty ?? true)
                }
            } footer: {
                if let log = runLog {
                    let lineCount = log.components(separatedBy: "\n").count
                    if lineCount > Self.logPreviewLineLimit {
                        Text("Showing the last \(Self.logPreviewLineLimit) of \(lineCount) lines.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if transcriptPreviewText.isEmpty {
                    Text(transcriptPreviewNote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(transcriptPreviewText)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                HStack {
                    Text("Transcript Preview")
                    Spacer()
                    Button("Refresh Preview") {
                        loadTranscriptPreview()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(!outputExists)
                }
            } footer: {
                if !transcriptPreviewText.isEmpty, !transcriptPreviewNote.isEmpty {
                    Text(transcriptPreviewNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsFullLog) {
            RunLogSheet(title: entry.recordingName, log: runLog ?? "")
        }
        .task(id: entry.id) {
            loadTranscriptPreview()
        }
        .onChange(of: entry.outputPath) { _ in
            loadTranscriptPreview()
        }
    }

    private func pathRow(_ title: String, path: String, warning: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(path)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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

/// The full run log in its own window-level surface, so it scrolls on its own.
private struct RunLogSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let log: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(log)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .onAppear {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 420, idealHeight: 560)
    }

    private static let bottomID = "run-log-bottom"
}

private extension TranscriptionHistoryEntry.Status {
    var systemImage: String {
        switch self {
        case .running:
            return "clock.fill"
        case .success:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "minus.circle.fill"
        }
    }

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
