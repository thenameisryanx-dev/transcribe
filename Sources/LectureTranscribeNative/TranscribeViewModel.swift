import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class TranscribeViewModel: ObservableObject, @unchecked Sendable {
    @Published var selectedPane: NavigationPane? = .transcribe

    @Published var audioFilePath = "" {
        didSet {
            if oldValue != audioFilePath {
                loadAudioTracks()
            }
            // A different recording starts a fresh draft, so results from the previous
            // file no longer drive the toolbar's primary action.
            guard oldValue != audioFilePath, !isRunning else { return }
            // Context describes one recording; keep it while choosing a file, but not for the next lecture.
            if completedAudioFilePath != nil {
                contextPrompt = ""
                keywordsText = ""
            }
            resetRunResult()
        }
    }
    @Published var outputFolderPath: String {
        didSet {
            guard oldValue != outputFolderPath else { return }
            UserDefaults.standard.set(outputFolderPath, forKey: Self.outputFolderDefaultsKey)
        }
    }
    @Published var selectedTranscriptionModel: TranscriptionModel = .gpt4oTranscribe {
        didSet {
            if !selectedTranscriptionModel.supportsDiarization && diarizeEnabled {
                diarizeEnabled = false
            }
            guard oldValue != selectedTranscriptionModel else { return }
            UserDefaults.standard.set(selectedTranscriptionModel.rawValue, forKey: Self.selectedModelDefaultsKey)
            // Picking another model after a finished run means transcribing the same recording again,
            // so the finished result gives way to a ready draft (file and context stay).
            if hasTranscribedCurrentRecording {
                resetRunResult()
            }
        }
    }
    /// ISO-639-1 code of the spoken language; empty means auto-detect.
    @Published var spokenLanguage: String {
        didSet {
            guard oldValue != spokenLanguage else { return }
            UserDefaults.standard.set(spokenLanguage, forKey: Self.spokenLanguageDefaultsKey)
        }
    }
    /// Description of the current recording, sent as the prompt with every chunk; empty sends no prompt.
    /// Belongs to the draft: cleared by Clear Draft and when a new file follows a finished run.
    @Published var contextPrompt = ""
    /// Contexts from earlier runs, most recent first, offered in the Recent menu.
    @Published private(set) var recentContextPrompts: [String] {
        didSet {
            UserDefaults.standard.set(recentContextPrompts, forKey: Self.recentContextPromptsDefaultsKey)
        }
    }
    /// Names and terms expected in the current recording, separated by commas or new lines (see `KeywordList`).
    /// Sent with every chunk to GPT Transcribe. Belongs to the draft, like `contextPrompt`.
    @Published var keywordsText = ""
    /// Keyword lists from earlier runs, most recent first, offered in the Recent menu.
    @Published private(set) var recentKeywords: [String] {
        didSet {
            UserDefaults.standard.set(recentKeywords, forKey: Self.recentKeywordsDefaultsKey)
        }
    }
    /// Consistency mode: transcribe chunks in order, adding the end of each chunk's transcript to the
    /// next chunk's prompt. Slower, so it's a remembered preference rather than on by default.
    /// Only GPT Transcribe uses it (see `supportsConsistencyMode`); the stored choice is kept when
    /// another model is selected so switching back restores it.
    @Published var consistencyModeEnabled: Bool {
        didSet {
            guard oldValue != consistencyModeEnabled else { return }
            UserDefaults.standard.set(consistencyModeEnabled, forKey: Self.consistencyModeDefaultsKey)
        }
    }
    /// Chunk length the user picked; nil uses `ChunkLength.standard`.
    @Published var chunkLengthPreference: ChunkLength? {
        didSet {
            guard oldValue != chunkLengthPreference else { return }
            if let chunkLengthPreference {
                UserDefaults.standard.set(chunkLengthPreference.rawValue, forKey: Self.chunkLengthDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.chunkLengthDefaultsKey)
            }
        }
    }
    @Published var diarizeEnabled = false {
        didSet {
            if diarizeEnabled && !selectedTranscriptionModel.supportsDiarization {
                diarizeEnabled = false
            }
            if diarizeEnabled && subtitlesEnabled {
                subtitlesEnabled = false
            }
        }
    }
    /// The model subtitle runs use, whichever model is selected (`TranscriptJob.diarizeModel`).
    nonisolated static let subtitlesModelDisplayName = "GPT-4o Transcribe Diarize"
    /// Write timed subtitles (.srt) for a video instead of a transcript. Subtitles always use the diarize model,
    /// the only one that returns timing, so this works with any selected model and turns speaker labels off.
    @Published var subtitlesEnabled = false {
        didSet {
            if subtitlesEnabled && diarizeEnabled {
                diarizeEnabled = false
            }
        }
    }
    /// With subtitles, also save a copy of the video with them built in, for QuickTime Player (which can't
    /// load an .srt file). Kept when subtitles are switched off, but only used with them.
    @Published var embedSubtitlesEnabled = false
    /// Whether the next run saves a subtitled copy of the video.
    var embedsSubtitlesForRun: Bool {
        subtitlesEnabled && embedSubtitlesEnabled
    }

    /// Audio tracks in the selected file; the picker only appears when there is more than one.
    @Published private(set) var audioTracks: [AudioTrack] = []
    /// Index of the audio track to transcribe (see `AudioTrack.index`).
    @Published var selectedAudioTrack = 0

    @Published var apiKeyStatusText = "API key: checking..."
    @Published var statusText = "Ready"
    @Published var progressValue: Double = 0
    @Published var logText = ""
    /// Warnings from the current run; a run with warnings finished but may be missing part of the transcript.
    @Published private(set) var runWarnings: [String] = []

    @Published var isRunning = false
    @Published var canOpenOutputFolder = false
    @Published var latestOutputPath: String?
    /// The copy of the video with subtitles built in that the finished run saved, if any.
    @Published private(set) var latestSubtitledVideoPath: String?
    /// The recording that produced `latestOutputPath`.
    @Published private(set) var completedAudioFilePath: String?

    @Published var showingAPIKeySheet = false
    @Published var pendingAPIKey = ""
    @Published var saveAPIKeyToKeychain = true
    /// Why the API key sheet opened on its own, e.g. after OpenAI rejected the key.
    @Published private(set) var apiKeySheetReason: String?
    /// Why the last key entered in the sheet wasn't accepted.
    @Published private(set) var apiKeyEntryError: String?
    @Published private(set) var isCheckingAPIKey = false

    @Published var showingErrorAlert = false
    @Published var errorMessage = ""
    @Published var showingClearDraftConfirmation = false
    @Published var howToGuideRequestToken = 0

    private let backend = BackendClient()
    /// The Tracks pane's editor; kept here so a finished subtitle run can open its video there.
    let trackEditor = TrackEditorModel()
    private let historyStore: TranscriptionHistoryStore
    private static let selectedModelDefaultsKey = "selectedTranscriptionModel"
    private static let outputFolderDefaultsKey = "outputFolderPath"
    // Keeps the older key so a language chosen before the dropdown carries over.
    private static let spokenLanguageDefaultsKey = "spokenLanguages"
    private static let recentContextPromptsDefaultsKey = "recentContextPrompts"
    private static let recentKeywordsDefaultsKey = "recentKeywords"
    private static let consistencyModeDefaultsKey = "consistencyMode"
    private static let chunkLengthDefaultsKey = "chunkLengthSeconds"
    private let defaultOutputFolderPath: String
    private var runTask: Task<Void, Never>?
    private var audioTracksTask: Task<Void, Never>?
    private var cancellationRequested = false
    private var activeHistoryEntryID: UUID?
    private var activeHistoryEntryFinalized = false
    private var lastHandledHowToGuideRequestToken = 0
    private var runFailedForAPIKey = false
    private var startTranscriptionAfterAPIKey = false

    @Published private(set) var historyEntries: [TranscriptionHistoryEntry] = []
    @Published var selectedHistoryEntryIDs: Set<UUID> = []

    /// Tests pass a store backed by a temporary file so they never touch the real run history.
    init(historyStore: TranscriptionHistoryStore = TranscriptionHistoryStore()) {
        self.historyStore = historyStore
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        defaultOutputFolderPath = downloads?.path ?? NSHomeDirectory()
        if let storedOutputFolder = UserDefaults.standard.string(forKey: Self.outputFolderDefaultsKey),
           !storedOutputFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            outputFolderPath = storedOutputFolder
        } else {
            outputFolderPath = defaultOutputFolderPath
        }
        spokenLanguage = SpokenLanguage.normalizedCode(
            UserDefaults.standard.string(forKey: Self.spokenLanguageDefaultsKey)
        )
        recentContextPrompts = UserDefaults.standard.stringArray(forKey: Self.recentContextPromptsDefaultsKey) ?? []
        recentKeywords = UserDefaults.standard.stringArray(forKey: Self.recentKeywordsDefaultsKey) ?? []
        consistencyModeEnabled = UserDefaults.standard.bool(forKey: Self.consistencyModeDefaultsKey)
        chunkLengthPreference = ChunkLength(rawValue: UserDefaults.standard.integer(forKey: Self.chunkLengthDefaultsKey))
        if let rawModel = UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey),
           let storedModel = TranscriptionModel(rawValue: rawModel)
        {
            selectedTranscriptionModel = storedModel
        }
        loadHistoryEntries()
        refreshAPIKeyStatus(verify: true)
    }

    var canStart: Bool {
        !isRunning && !audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canClearDraft: Bool {
        guard !isRunning else { return false }
        let hasAudioPath = !audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasRunState = progressValue > 0 || !logText.isEmpty || statusText != "Ready" || latestOutputPath != nil || canOpenOutputFolder
        return hasAudioPath || hasRunState
    }

    /// True once the selected recording has been transcribed successfully.
    var hasTranscribedCurrentRecording: Bool {
        guard !isRunning, latestOutputPath != nil, let completedAudioFilePath else { return false }
        return completedAudioFilePath == audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCancel: Bool {
        isRunning
    }

    var progressLabel: String {
        "\(Int(progressValue.rounded()))%"
    }

    /// Whether the model that will run needs a language. GPT Transcribe does, but subtitle runs use the
    /// diarize model whatever is selected, and it can auto-detect.
    var runRequiresSpokenLanguage: Bool {
        !subtitlesEnabled && selectedTranscriptionModel.requiresSpokenLanguages
    }

    /// Named in the toolbar's model menu instead of the selected model, which then can't be changed: subtitle
    /// runs always use the diarize model.
    var modelMenuFixedName: String? {
        subtitlesEnabled ? Self.subtitlesModelDisplayName : nil
    }

    /// The model whose language rules apply: the one that will run.
    var languageModelDisplayName: String {
        subtitlesEnabled ? Self.subtitlesModelDisplayName : selectedTranscriptionModel.displayName
    }

    /// Language codes sent with the run. Auto-detect becomes English when the model needs a language.
    var spokenLanguageCodesForRun: [String] {
        if !spokenLanguage.isEmpty { return [spokenLanguage] }
        return runRequiresSpokenLanguage ? [SpokenLanguage.fallbackCode] : []
    }

    /// The language the run will use. Auto-detect shows as English when the model needs a language, but the
    /// stored choice stays auto-detect so switching to a model (or subtitles) that can detect it restores it.
    var effectiveSpokenLanguage: String {
        get { spokenLanguageCodesForRun.first ?? "" }
        set { spokenLanguage = newValue }
    }

    var isAutoDetectAvailable: Bool {
        !runRequiresSpokenLanguage
    }

    var spokenLanguageSummary: String {
        SpokenLanguage(code: effectiveSpokenLanguage).displayName
    }

    /// The pane's options as they stand; `RunRequest` works out which of them a run uses.
    var runOptions: RunRequest.Options {
        RunRequest.Options(
            model: selectedTranscriptionModel,
            diarize: diarizeEnabled,
            subtitles: subtitlesEnabled,
            embedSubtitles: embedSubtitlesEnabled,
            audioTrack: selectedAudioTrack,
            languages: spokenLanguageCodesForRun,
            contextPrompt: contextPrompt,
            consistencyMode: consistencyModeEnabled,
            chunkLength: effectiveChunkLength,
            keywordsText: keywordsText
        )
    }

    var trimmedContextPrompt: String {
        contextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The diarize model (used for speaker labels and subtitles) doesn't accept a prompt, so context and
    /// consistency mode don't apply.
    var isContextAvailable: Bool {
        !diarizeEnabled && !subtitlesEnabled
    }

    /// Diarized and subtitle runs use their own chunk size.
    var isChunkLengthAvailable: Bool {
        !diarizeEnabled && !subtitlesEnabled
    }

    var hasMultipleAudioTracks: Bool {
        audioTracks.count > 1
    }

    /// Set when the chosen track is tagged with a language other than the spoken language the model is told.
    var audioTrackLanguageMismatch: String? {
        guard hasMultipleAudioTracks,
              let track = audioTracks.first(where: { $0.index == selectedAudioTrack }),
              let trackCode = track.languageCode, let trackName = track.languageName,
              !effectiveSpokenLanguage.isEmpty, trackCode != effectiveSpokenLanguage
        else { return nil }
        return "This track is \(trackName), but the spoken language is \(spokenLanguageSummary). Pick another track, or change the spoken language."
    }

    /// True when the finished run wrote subtitles rather than a transcript.
    var latestOutputIsSubtitles: Bool {
        latestOutputPath.map { ($0 as NSString).pathExtension.lowercased() == "srt" } ?? false
    }

    var effectiveChunkLength: ChunkLength {
        chunkLengthPreference ?? .standard
    }

    /// Keywords only reach GPT Transcribe, and never the diarize model.
    var isKeywordsAvailable: Bool {
        isContextAvailable && selectedTranscriptionModel.supportsKeywords
    }

    var isConsistencyModeAvailable: Bool {
        isContextAvailable && selectedTranscriptionModel.supportsConsistencyMode
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

    /// True when there's no key, or OpenAI rejected the one we have.
    var apiKeyNeedsAttention: Bool {
        let status = apiKeyStatusText.lowercased()
        return status.contains("required") || status.contains("rejected")
    }

    func refreshAPIKeyStatus(verify: Bool = false) {
        Task {
            do {
                let status = try await backend.fetchAPIKeyStatus(verify: verify)
                apiKeyStatusText = "API key: \(status)"
            } catch {
                apiKeyStatusText = "API key: unknown"
            }
        }
    }

    func presentAPIKeySheet() {
        presentAPIKeySheet(reason: nil, startTranscriptionAfterward: false)
    }

    private func presentAPIKeySheet(reason: String?, startTranscriptionAfterward: Bool) {
        pendingAPIKey = ""
        saveAPIKeyToKeychain = true
        apiKeySheetReason = reason
        apiKeyEntryError = nil
        startTranscriptionAfterAPIKey = startTranscriptionAfterward
        showingAPIKeySheet = true
    }

    func dismissAPIKeySheet() {
        showingAPIKeySheet = false
        startTranscriptionAfterAPIKey = false
    }

    /// Checks the key with OpenAI and saves it. A key that doesn't work keeps the sheet open with the reason.
    func submitAPIKey() {
        let key = pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isCheckingAPIKey else { return }

        isCheckingAPIKey = true
        apiKeyEntryError = nil
        Task {
            defer { isCheckingAPIKey = false }
            do {
                let status = try await backend.setAPIKey(key, saveToKeychain: saveAPIKeyToKeychain)
                apiKeyStatusText = "API key: \(status)"
                showingAPIKeySheet = false
                appendLog("API key updated (\(status)).")
                if startTranscriptionAfterAPIKey {
                    startTranscriptionAfterAPIKey = false
                    if canStart {
                        startTranscription()
                    }
                }
            } catch {
                apiKeyEntryError = error.localizedDescription
            }
        }
    }

    func browseAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Select audio file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Containers like .mkv/.webm aren't mapped to .movie unless another
        // installed app declares them, so add them by extension explicitly.
        let extraVideoTypes = ["mkv", "webm", "avi"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowedContentTypes = [
            .audio,
            .mpeg4Movie,
            .movie,
            .quickTimeMovie,
        ] + extraVideoTypes

        if panel.runModal() == .OK, let path = panel.url?.path {
            selectAudioFile(path)
        }
    }

    /// Choosing a file always gives a ready draft. Re-choosing the recording that was just transcribed
    /// (e.g. to run it with another model) doesn't change `audioFilePath`, so reset the result here.
    private func selectAudioFile(_ path: String) {
        guard !isRunning else { return }
        if path == audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines) {
            resetRunResult()
        } else {
            audioFilePath = path
        }
    }

    func loadDroppedAudioFile(_ url: URL) {
        guard !isRunning else { return }
        guard url.isFileURL else {
            showError("Dropped item is not a local file.")
            return
        }

        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            showError("Dropped file no longer exists:\n\(path)")
            return
        }

        guard !isDirectory.boolValue else {
            showError("Drop an audio/video file, not a folder.")
            return
        }

        selectAudioFile(path)
    }

    func reportDroppedAudioFileReadFailure(details: String? = nil) {
        if let details, !details.isEmpty {
            showError("Could not read the dropped file: \(details)")
        } else {
            showError("Could not read the dropped file. Please try dropping it again.")
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

    func openLatestTranscript() {
        guard let latestOutputPath, FileManager.default.fileExists(atPath: latestOutputPath) else {
            showError("Transcript file no longer exists:\n\(latestOutputPath ?? "")")
            return
        }
        Self.openOrReveal(URL(fileURLWithPath: latestOutputPath))
    }

    /// Opens the video just subtitled in the Tracks pane, with the new subtitles added as the default track.
    func editTracksOfLatestRun() {
        guard let completedAudioFilePath, let latestOutputPath, latestOutputIsSubtitles else { return }
        selectedPane = .tracks
        trackEditor.requestOpen(
            videoPath: completedAudioFilePath,
            addingSubtitleFile: latestOutputPath,
            language: effectiveSpokenLanguage
        )
    }

    func openLatestSubtitledVideo() {
        guard let latestSubtitledVideoPath, FileManager.default.fileExists(atPath: latestSubtitledVideoPath) else {
            showError("Video file no longer exists:\n\(latestSubtitledVideoPath ?? "")")
            return
        }
        Self.openOrReveal(URL(fileURLWithPath: latestSubtitledVideoPath))
    }

    /// Opens a file in its default app, or shows it in Finder when no app opens that type (e.g. .srt files).
    private static func openOrReveal(_ url: URL) {
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func revealLatestTranscript() {
        guard let latestOutputPath, FileManager.default.fileExists(atPath: latestOutputPath) else {
            openOutputFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: latestOutputPath)])
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

        Self.openOrReveal(URL(fileURLWithPath: outputPath))
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
        // Restore the model before diarization; diarizeEnabled is reset when the model can't diarize.
        let entryModel = entry.model.flatMap(TranscriptionModel.init(rawValue:))
        if entry.diarize {
            selectedTranscriptionModel = entryModel.flatMap { $0.supportsDiarization ? $0 : nil } ?? .gpt4oTranscribe
        } else if let entryModel {
            selectedTranscriptionModel = entryModel
        }
        diarizeEnabled = entry.diarize
        subtitlesEnabled = entry.subtitles ?? false
        embedSubtitlesEnabled = entry.embedSubtitles ?? false
        // Set after audioFilePath, whose change resets the track; the track list loading afterwards keeps it.
        selectedAudioTrack = entry.audioTrack ?? 0
        if let chunkLength = entry.chunkSeconds.flatMap(ChunkLength.init(rawValue:)) {
            chunkLengthPreference = chunkLength
        }
        // The same prompt settings too, so the run can reuse chunks a failed or cancelled run saved.
        // Set after audioFilePath, whose change can clear them. Speaker-label and subtitle runs sent none.
        if !entry.diarize, entry.subtitles != true {
            contextPrompt = entry.context ?? ""
            keywordsText = KeywordList.displayText(entry.keywords ?? [])
            if selectedTranscriptionModel.supportsConsistencyMode, let consistencyMode = entry.consistencyMode {
                consistencyModeEnabled = consistencyMode
            }
        }
        selectedPane = .transcribe
        startTranscription()
    }

    func deleteSelectedHistoryEntries() {
        guard !selectedHistoryEntryIDs.isEmpty else { return }

        let deletion = RunHistory.deleting(selectedHistoryEntryIDs, from: historyEntries)
        guard deletion.deletedAny else {
            showError("Cannot delete a run while it is still in progress.")
            return
        }

        historyEntries = deletion.remaining
        selectedHistoryEntryIDs = RunHistory.selection(
            selectedHistoryEntryIDs,
            in: historyEntries,
            preferring: deletion.keepSelected
        )
        saveHistoryEntries()

        if deletion.skippedRunning > 0 {
            showError("Skipped \(deletion.skippedRunning) run(s) that are still in progress.")
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

        if apiKeyNeedsAttention {
            let reason = apiKeyStatusText.lowercased().contains("rejected")
                ? "OpenAI didn't accept your saved API key. Enter a working key to start transcribing."
                : "Add your OpenAI API key to start transcribing."
            presentAPIKeySheet(reason: reason, startTranscriptionAfterward: true)
            return
        }

        let trimmedPath = audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            showError("Choose an audio file first.")
            return
        }

        guard FileManager.default.fileExists(atPath: trimmedPath) else {
            showError("Audio file not found:\n\(trimmedPath)")
            return
        }

        if isKeywordsAvailable, let invalid = KeywordList.parse(keywordsText).first(where: KeywordList.isRejected) {
            showError("The keyword \"\(invalid)\" contains < or >, which OpenAI doesn't accept. Remove those characters, then try again.")
            return
        }

        let normalizedOutputDirectory = normalizeOutputDirectoryPath(outputFolderPath)
        guard ensureOutputDirectoryAvailable(at: normalizedOutputDirectory) else {
            return
        }

        outputFolderPath = normalizedOutputDirectory
        cancellationRequested = false
        progressValue = 0
        statusText = "Starting..."
        logText = ""
        runWarnings = []
        latestOutputPath = nil
        latestSubtitledVideoPath = nil
        completedAudioFilePath = nil
        canOpenOutputFolder = false
        runFailedForAPIKey = false
        isRunning = true
        let request = RunRequest(inputPath: trimmedPath, outputDirectory: normalizedOutputDirectory, options: runOptions)
        if diarizeEnabled != request.diarize {
            diarizeEnabled = request.diarize
        }
        if !request.context.isEmpty {
            recentContextPrompts = RecentContextPrompts.adding(request.context, to: recentContextPrompts)
        }
        if !request.keywords.isEmpty {
            recentKeywords = RecentContextPrompts.adding(KeywordList.displayText(request.keywords), to: recentKeywords)
        }
        beginHistoryEntry(request.historyEntry())

        runTask = Task { [weak self] in
            guard let self else { return }

            // Funnel run events through one FIFO stream so they apply in order and are fully
            // drained before the run is finalized below.
            let (events, eventContinuation) = AsyncStream.makeStream(of: BackendStreamEvent.self)
            let eventConsumer = Task { @MainActor [weak self] in
                for await event in events {
                    self?.apply(event: event)
                }
            }

            var runError: Error?
            do {
                try await backend.startTranscription(request) { event in
                    eventContinuation.yield(event)
                }
            } catch {
                runError = error
            }
            eventContinuation.finish()
            await eventConsumer.value

            if activeHistoryEntryFinalized {
                // A `done` or `error` event already recorded the outcome.
            } else if runError is CancellationError || (runError != nil && cancellationRequested) {
                statusText = "Cancelled"
                appendLog("Run cancelled.")
                finalizeActiveHistoryEntry(status: .cancelled, errorMessage: "Run cancelled.")
            } else {
                let message = runError?.localizedDescription ?? "The transcription ended without reporting a result."
                statusText = "Failed"
                appendLog("Error: \(message)")
                showError(message)
                finalizeActiveHistoryEntry(status: .failed, errorMessage: message)
            }

            isRunning = false
            cancellationRequested = false
            runTask = nil
            clearActiveHistoryTracking()
        }
    }

    func cancelTranscription() {
        guard isRunning else { return }
        guard !cancellationRequested else { return }
        cancellationRequested = true
        statusText = "Cancelling..."
        appendLog("Cancelling run...")
        runTask?.cancel()
        backend.cancelActiveRun()
    }

    // Internal (not private) so tests can play back a finished run.
    func apply(event: BackendStreamEvent) {
        switch event {
        case let .log(message):
            appendLog(message)
        case let .warning(message):
            runWarnings.append(message)
            appendLog("WARNING: \(message)")
        case let .status(message):
            statusText = message
            appendLog(message)
        case let .progress(value):
            progressValue = min(max(value, 0), 100)
        case let .done(path):
            progressValue = 100
            statusText = runWarnings.isEmpty ? "Done" : "Finished with warnings"
            latestOutputPath = path
            completedAudioFilePath = audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
            canOpenOutputFolder = true
            appendLog("Done. Wrote: \(path)")
            finalizeActiveHistoryEntry(status: .success, outputPath: path, errorMessage: nil)
        case let .subtitledCopy(path):
            latestSubtitledVideoPath = path
        case .apiKeyProblem:
            runFailedForAPIKey = true
        case let .error(message):
            if cancellationRequested {
                appendLog("Run cancellation completed.")
                return
            }
            statusText = "Failed"
            appendLog("Error: \(message)")
            if runFailedForAPIKey {
                // Ask for a working key instead of showing an alert; the run restarts once one is saved.
                let hadKey = !apiKeyStatusText.lowercased().contains("required")
                if hadKey {
                    apiKeyStatusText = "API key: rejected by OpenAI"
                }
                presentAPIKeySheet(
                    reason: hadKey
                        ? "OpenAI didn't accept your API key, so the transcription stopped. Enter a working key to try again."
                        : message,
                    startTranscriptionAfterward: true
                )
            } else {
                showError(message)
            }
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
        errorMessage = Self.alertSummary(for: message)
        showingErrorAlert = true
    }

    /// Keeps the error alert short enough to fit on screen; the full message stays in the run log and history.
    nonisolated static func alertSummary(for message: String, maxLength: Int = 300) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstParagraph = trimmed.components(separatedBy: "\n\n").first ?? trimmed
        var summary = firstParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.count > maxLength {
            summary = String(summary.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        if summary != trimmed {
            summary += "\n\nFull details are in the Run Log."
        }
        return summary
    }

    /// File ▸ New Transcription: return to an empty Transcribe pane. Run history is kept.
    func startNewTranscription() {
        guard !isRunning else { return }
        selectedPane = .transcribe
        clearDraft()
    }

    func requestClearDraft() {
        guard canClearDraft else { return }
        showingClearDraftConfirmation = true
    }

    func clearDraft() {
        guard !isRunning else { return }

        // Reset run-scoped fields while preserving API key state, options, and history.
        cancellationRequested = false
        audioFilePath = ""
        contextPrompt = ""
        keywordsText = ""
        statusText = "Ready"
        progressValue = 0
        logText = ""
        runWarnings = []
        latestOutputPath = nil
        latestSubtitledVideoPath = nil
        completedAudioFilePath = nil
        canOpenOutputFolder = false
        showingErrorAlert = false
        errorMessage = ""
        showingClearDraftConfirmation = false
    }

    /// Lists the selected file's audio tracks and picks the one to transcribe.
    private func loadAudioTracks() {
        audioTracksTask?.cancel()
        audioTracks = []
        selectedAudioTrack = 0
        let path = audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        audioTracksTask = Task { [weak self, backend] in
            let tracks = (try? await backend.fetchAudioTracks(inputPath: path)) ?? []
            guard let self, !Task.isCancelled,
                  self.audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines) == path
            else { return }
            self.audioTracks = tracks
            // A run that already started (e.g. Re-run) keeps the track it was given.
            if !self.isRunning {
                self.selectedAudioTrack = AudioTrack.preferredIndex(in: tracks, spokenLanguage: self.effectiveSpokenLanguage)
            }
        }
    }

    private func resetRunResult() {
        runWarnings = []
        statusText = "Ready"
        progressValue = 0
        latestOutputPath = nil
        latestSubtitledVideoPath = nil
        completedAudioFilePath = nil
        canOpenOutputFolder = false
    }

    private func normalizeOutputDirectoryPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPath = defaultOutputFolderPath
        let candidatePath = trimmedPath.isEmpty ? fallbackPath : trimmedPath
        return (candidatePath as NSString).expandingTildeInPath
    }

    private func ensureOutputDirectoryAvailable(at path: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                showError("Output path is a file:\n\(path)\n\nChoose a folder instead.")
                return false
            }
        } else {
            do {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                showError("Could not create output folder:\n\(path)\n\n\(error.localizedDescription)")
                return false
            }
        }

        guard fileManager.isWritableFile(atPath: path) else {
            showError("Output folder is not writable:\n\(path)")
            return false
        }

        return true
    }

    private func loadHistoryEntries() {
        do {
            let loaded = RunHistory.loaded(try historyStore.loadEntries())
            historyEntries = loaded.entries
            selectedHistoryEntryIDs = RunHistory.selection(selectedHistoryEntryIDs, in: historyEntries)
            if loaded.changed {
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

    private func beginHistoryEntry(_ entry: TranscriptionHistoryEntry) {
        activeHistoryEntryID = entry.id
        activeHistoryEntryFinalized = false
        historyEntries = RunHistory.adding(entry, to: historyEntries)
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
        activeHistoryEntryFinalized = true
        guard let finished = RunHistory.finishing(
            activeHistoryEntryID,
            in: historyEntries,
            status: status,
            outputPath: outputPath,
            errorMessage: errorMessage,
            warnings: runWarnings,
            log: logText
        ) else {
            return
        }
        historyEntries = finished
        selectedHistoryEntryIDs = [activeHistoryEntryID]
        saveHistoryEntries()
    }

    private func clearActiveHistoryTracking() {
        activeHistoryEntryID = nil
        activeHistoryEntryFinalized = false
    }
}
