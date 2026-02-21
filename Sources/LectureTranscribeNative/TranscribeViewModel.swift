import AppKit
import Foundation
import UniformTypeIdentifiers

enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt4oTranscribe:
            return "GPT-4o Transcribe"
        case .gpt4oMiniTranscribe:
            return "GPT-4o Mini Transcribe"
        }
    }

    var hoverDescription: String {
        switch self {
        case .gpt4oTranscribe:
            return "Best accuracy and supports speaker diarization."
        case .gpt4oMiniTranscribe:
            return "Fast, cost-efficient transcription. Speaker diarization is unavailable."
        }
    }

    var supportsDiarization: Bool {
        self == .gpt4oTranscribe
    }
}

@MainActor
final class TranscribeViewModel: ObservableObject, @unchecked Sendable {
    @Published var selectedPane: NavigationPane? = .transcribe

    @Published var audioFilePath = ""
    @Published var outputFolderPath: String
    @Published var selectedTranscriptionModel: TranscriptionModel = .gpt4oTranscribe {
        didSet {
            if !selectedTranscriptionModel.supportsDiarization && diarizeEnabled {
                diarizeEnabled = false
            }
            guard oldValue != selectedTranscriptionModel else { return }
            UserDefaults.standard.set(selectedTranscriptionModel.rawValue, forKey: Self.selectedModelDefaultsKey)
        }
    }
    @Published var diarizeEnabled = false {
        didSet {
            if diarizeEnabled && !selectedTranscriptionModel.supportsDiarization {
                diarizeEnabled = false
            }
        }
    }

    @Published var apiKeyStatusText = "API key: checking..."
    @Published var statusText = "Ready"
    @Published var progressValue: Double = 0
    @Published var logText = ""

    @Published var isRunning = false
    @Published var canOpenOutputFolder = false
    @Published var latestOutputPath: String?
    @Published var canCreateNewTranscript = false

    @Published var showingAPIKeySheet = false
    @Published var pendingAPIKey = ""
    @Published var saveAPIKeyToKeychain = true

    @Published var showingErrorAlert = false
    @Published var errorMessage = ""
    @Published var howToGuideRequestToken = 0

    private let backend = BackendClient()
    private let historyStore = TranscriptionHistoryStore()
    private let maxHistoryEntries = 200
    private static let selectedModelDefaultsKey = "selectedTranscriptionModel"
    private let defaultOutputFolderPath: String
    private var runTask: Task<Void, Never>?
    private var activeHistoryEntryID: UUID?
    private var activeHistoryEntryFinalized = false
    private var lastHandledHowToGuideRequestToken = 0

    @Published private(set) var historyEntries: [TranscriptionHistoryEntry] = []
    @Published var selectedHistoryEntryIDs: Set<UUID> = []

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        defaultOutputFolderPath = downloads?.path ?? NSHomeDirectory()
        outputFolderPath = defaultOutputFolderPath
        if let rawModel = UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey),
           let storedModel = TranscriptionModel(rawValue: rawModel)
        {
            selectedTranscriptionModel = storedModel
        }
        loadHistoryEntries()
        refreshAPIKeyStatus()
    }

    var canStart: Bool {
        !isRunning && !audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var progressLabel: String {
        "\(Int(progressValue.rounded()))%"
    }

    var isDiarizationAvailable: Bool {
        selectedTranscriptionModel.supportsDiarization
    }

    var selectedHistoryEntry: TranscriptionHistoryEntry? {
        guard selectedHistoryEntryIDs.count == 1, let selectedHistoryEntryID = selectedHistoryEntryIDs.first else {
            return nil
        }
        return historyEntries.first(where: { $0.id == selectedHistoryEntryID })
    }

    var selectedHistoryEntryCount: Int {
        selectedHistoryEntryIDs.count
    }

    var canDeleteSelectedHistoryEntries: Bool {
        historyEntries.contains { entry in
            selectedHistoryEntryIDs.contains(entry.id) && entry.status != .running
        }
    }

    func refreshAPIKeyStatus() {
        Task {
            do {
                let status = try await backend.fetchAPIKeyStatus()
                apiKeyStatusText = "API key: \(status)"
            } catch {
                apiKeyStatusText = "API key: unknown"
            }
        }
    }

    func presentAPIKeySheet() {
        pendingAPIKey = ""
        saveAPIKeyToKeychain = true
        showingAPIKeySheet = true
    }

    func dismissAPIKeySheet() {
        showingAPIKeySheet = false
    }

    func submitAPIKey() {
        let key = pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        Task {
            do {
                let status = try await backend.setAPIKey(key, saveToKeychain: saveAPIKeyToKeychain)
                apiKeyStatusText = "API key: \(status)"
                showingAPIKeySheet = false
                appendLog("API key updated (\(status)).")
            } catch {
                showingAPIKeySheet = false
                appendLog("API key update failed: \(error.localizedDescription)")
                showError(error.localizedDescription)
            }
        }
    }

    func browseAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Select audio file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .audio,
            .mpeg4Movie,
            .movie,
            .quickTimeMovie,
        ]

        if panel.runModal() == .OK, let path = panel.url?.path {
            audioFilePath = path
        }
    }

    func browseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select output folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputFolderPath)

        if panel.runModal() == .OK, let path = panel.url?.path {
            outputFolderPath = path
        }
    }

    func openOutputFolder() {
        let targetPath = outputFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultOutputFolderPath
            : outputFolderPath
        NSWorkspace.shared.open(URL(fileURLWithPath: targetPath))
    }

    func openHistoryOutput(_ entry: TranscriptionHistoryEntry) {
        guard let outputPath = entry.outputPath else {
            showError("This run does not have an output file path.")
            return
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            showError("Transcript file no longer exists:\n\(outputPath)")
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: outputPath))
    }

    func revealHistoryOutput(_ entry: TranscriptionHistoryEntry) {
        if let outputPath = entry.outputPath, FileManager.default.fileExists(atPath: outputPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outputPath)])
            return
        }

        guard FileManager.default.fileExists(atPath: entry.outputDirectory) else {
            showError("Output folder no longer exists:\n\(entry.outputDirectory)")
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: entry.outputDirectory))
    }

    func rerunHistoryEntry(_ entry: TranscriptionHistoryEntry) {
        audioFilePath = entry.inputPath
        outputFolderPath = entry.outputDirectory
        diarizeEnabled = entry.diarize
        selectedPane = .transcribe
        startTranscription()
    }

    func deleteSelectedHistoryEntries() {
        guard !selectedHistoryEntryIDs.isEmpty else { return }

        let runningSelectedCount = historyEntries.reduce(into: 0) { count, entry in
            if selectedHistoryEntryIDs.contains(entry.id), entry.status == .running {
                count += 1
            }
        }

        let deletableIDs = Set(historyEntries.compactMap { entry -> UUID? in
            guard selectedHistoryEntryIDs.contains(entry.id), entry.status != .running else {
                return nil
            }
            return entry.id
        })

        guard !deletableIDs.isEmpty else {
            showError("Cannot delete a run while it is still in progress.")
            return
        }

        let preferredSelectionID = selectedHistoryEntryIDs.first(where: { !deletableIDs.contains($0) })
        historyEntries.removeAll { entry in
            deletableIDs.contains(entry.id)
        }
        normalizeHistorySelection(preferredID: preferredSelectionID)

        saveHistoryEntries()

        if runningSelectedCount > 0 {
            showError("Skipped \(runningSelectedCount) run(s) that are still in progress.")
        }
    }

    func requestHowToGuide() {
        howToGuideRequestToken += 1
        selectedPane = .transcribe
    }

    func consumeHowToGuideRequestIfNeeded() -> Bool {
        guard howToGuideRequestToken > lastHandledHowToGuideRequestToken else {
            return false
        }
        lastHandledHowToGuideRequestToken = howToGuideRequestToken
        return true
    }

    func startTranscription() {
        guard runTask == nil else { return }

        let trimmedPath = audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            showError("Choose an audio file first.")
            return
        }

        guard FileManager.default.fileExists(atPath: trimmedPath) else {
            showError("Audio file not found:\n\(trimmedPath)")
            return
        }

        progressValue = 0
        statusText = "Starting..."
        logText = ""
        latestOutputPath = nil
        canOpenOutputFolder = false
        canCreateNewTranscript = false
        isRunning = true
        let shouldDiarize = diarizeEnabled && selectedTranscriptionModel.supportsDiarization
        if diarizeEnabled != shouldDiarize {
            diarizeEnabled = shouldDiarize
        }
        beginHistoryEntry(inputPath: trimmedPath, outputDirectory: outputFolderPath, diarize: shouldDiarize)

        runTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await backend.startTranscription(
                    inputPath: trimmedPath,
                    outputDirectory: outputFolderPath,
                    diarize: shouldDiarize,
                    model: selectedTranscriptionModel.rawValue
                ) { [weak self] event in
                    Task { @MainActor in
                        self?.apply(event: event)
                    }
                }
            } catch is CancellationError {
                statusText = "Cancelled"
                finalizeActiveHistoryEntry(status: .cancelled, errorMessage: "Run cancelled.")
            } catch {
                statusText = "Failed"
                appendLog("Error: \(error.localizedDescription)")
                showError(error.localizedDescription)
                finalizeActiveHistoryEntry(status: .failed, errorMessage: error.localizedDescription)
            }

            isRunning = false
            runTask = nil
            clearActiveHistoryTracking()
        }
    }

    private func apply(event: BackendStreamEvent) {
        switch event {
        case let .log(message):
            appendLog(message)
        case let .status(message):
            statusText = message
            appendLog(message)
        case let .progress(value):
            progressValue = min(max(value, 0), 100)
        case let .done(path):
            progressValue = 100
            statusText = "Done"
            latestOutputPath = path
            canOpenOutputFolder = true
            // Show a single clear action after success so users can quickly start over.
            canCreateNewTranscript = true
            appendLog("Done. Wrote: \(path)")
            finalizeActiveHistoryEntry(status: .success, outputPath: path, errorMessage: nil)
        case let .error(message):
            statusText = "Failed"
            appendLog("Error: \(message)")
            showError(message)
            finalizeActiveHistoryEntry(status: .failed, errorMessage: message)
        }
    }

    private func appendLog(_ line: String) {
        if logText.isEmpty {
            logText = line
        } else {
            logText += "\n\(line)"
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingErrorAlert = true
    }

    func createNewTranscript() {
        guard !isRunning else { return }

        // Reset run-scoped fields while preserving API key state and saved history.
        audioFilePath = ""
        outputFolderPath = defaultOutputFolderPath
        diarizeEnabled = false
        statusText = "Ready"
        progressValue = 0
        logText = ""
        latestOutputPath = nil
        canOpenOutputFolder = false
        canCreateNewTranscript = false
        showingErrorAlert = false
        errorMessage = ""
    }

    private func loadHistoryEntries() {
        do {
            let loadedEntries = try historyStore.loadEntries()
            var didMutateInterruptedEntries = false
            let normalizedEntries = loadedEntries.map { entry -> TranscriptionHistoryEntry in
                guard entry.status == .running else { return entry }

                // If a run is still marked as running on launch, the app was closed mid-run.
                var interrupted = entry
                interrupted.status = .cancelled
                interrupted.finishedAt = interrupted.finishedAt ?? interrupted.startedAt
                interrupted.errorMessage = interrupted.errorMessage ?? "Run interrupted before completion."
                didMutateInterruptedEntries = true
                return interrupted
            }

            historyEntries = normalizedEntries.sorted(by: Self.sortHistoryEntriesNewestFirst)
            normalizeHistorySelection()
            if didMutateInterruptedEntries {
                saveHistoryEntries()
            }
        } catch {
            appendLog("Could not load history: \(error.localizedDescription)")
            historyEntries = []
            selectedHistoryEntryIDs = []
        }
    }

    private func saveHistoryEntries() {
        do {
            try historyStore.saveEntries(historyEntries)
        } catch {
            appendLog("Could not save history: \(error.localizedDescription)")
        }
    }

    private func normalizeHistorySelection(preferredID: UUID? = nil) {
        let currentIDs = Set(historyEntries.map(\.id))
        selectedHistoryEntryIDs.formIntersection(currentIDs)

        if selectedHistoryEntryIDs.isEmpty, let preferredID, currentIDs.contains(preferredID) {
            selectedHistoryEntryIDs = [preferredID]
            return
        }

        if selectedHistoryEntryIDs.isEmpty, let firstEntryID = historyEntries.first?.id {
            selectedHistoryEntryIDs = [firstEntryID]
        }
    }

    private func beginHistoryEntry(inputPath: String, outputDirectory: String, diarize: Bool) {
        let entry = TranscriptionHistoryEntry(
            id: UUID(),
            startedAt: Date(),
            finishedAt: nil,
            inputPath: inputPath,
            outputPath: nil,
            outputDirectory: outputDirectory,
            diarize: diarize,
            status: .running,
            errorMessage: nil
        )

        activeHistoryEntryID = entry.id
        activeHistoryEntryFinalized = false

        historyEntries.removeAll(where: { $0.id == entry.id })
        historyEntries.insert(entry, at: 0)
        if historyEntries.count > maxHistoryEntries {
            historyEntries.removeSubrange(maxHistoryEntries...)
        }

        selectedHistoryEntryIDs = [entry.id]
        saveHistoryEntries()
    }

    private func finalizeActiveHistoryEntry(
        status: TranscriptionHistoryEntry.Status,
        outputPath: String? = nil,
        errorMessage: String?
    ) {
        guard let activeHistoryEntryID, !activeHistoryEntryFinalized else {
            return
        }

        guard let index = historyEntries.firstIndex(where: { $0.id == activeHistoryEntryID }) else {
            activeHistoryEntryFinalized = true
            return
        }

        historyEntries[index].status = status
        historyEntries[index].finishedAt = Date()
        historyEntries[index].errorMessage = errorMessage
        if let outputPath {
            historyEntries[index].outputPath = outputPath
        }

        // Move updated entries to the top in case list ordering changed while running.
        let updatedEntry = historyEntries.remove(at: index)
        historyEntries.insert(updatedEntry, at: 0)
        selectedHistoryEntryIDs = [updatedEntry.id]

        activeHistoryEntryFinalized = true
        saveHistoryEntries()
    }

    private func clearActiveHistoryTracking() {
        activeHistoryEntryID = nil
        activeHistoryEntryFinalized = false
    }

    private static func sortHistoryEntriesNewestFirst(_ lhs: TranscriptionHistoryEntry, _ rhs: TranscriptionHistoryEntry) -> Bool {
        lhs.startedAt > rhs.startedAt
    }
}
