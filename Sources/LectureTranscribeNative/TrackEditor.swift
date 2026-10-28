import AppKit
import Foundation
import UniformTypeIdentifiers

/// One track in a video, as listed by the backend's `tracks` command.
struct MediaTrack: Equatable, Sendable {
    /// Position among all of the file's tracks (ffmpeg's `0:N`).
    let index: Int
    /// "video", "audio", "subtitle", "attachment" or "data".
    let kind: String
    let codec: String
    /// The file's language tag, usually three letters ("eng"); empty when untagged.
    let language: String
    let title: String
    let `default`: Bool
    let forced: Bool
    let channels: Int?
    /// True for subtitles stored as text (not pictures).
    let text: Bool
    /// The sample format's tag, like "tx3g" for subtitles Apple's players show.
    var codecTag = ""
}

/// An audio or subtitle track in the track editor: one of the video's own, or a subtitle file being added.
struct EditableTrack: Identifiable, Equatable {
    enum Kind: String, Sendable {
        case audio
        case subtitle
    }

    enum Source: Equatable {
        /// A track of the video, by its index among all of the file's tracks.
        case original(index: Int)
        /// A subtitle file to add.
        case file(path: String)
    }

    let id = UUID()
    let kind: Kind
    let source: Source
    let codec: String
    let channels: Int?
    /// Two-letter code when the language is one the app knows (see `TrackLanguage`), else the file's tag;
    /// empty when unknown.
    var language: String
    var title: String
    var isDefault: Bool
    var isForced: Bool
    /// Unticked tracks of the video are left out of the copy.
    var keep = true

    var isAdded: Bool {
        if case .file = source { return true }
        return false
    }

    /// e.g. "Track 3 · E-AC-3 · 5.1" or "Added · Episode 3.srt"
    var sourceDescription: String {
        switch source {
        case let .original(index):
            var parts = ["Track \(index + 1)", Self.codecName(codec)]
            if let channels = Self.channelName(channels) {
                parts.append(channels)
            }
            return parts.joined(separator: " · ")
        case let .file(path):
            return "Added · " + (path as NSString).lastPathComponent
        }
    }

    private static func codecName(_ codec: String) -> String {
        switch codec {
        case "eac3": return "E-AC-3"
        case "ac3": return "AC-3"
        case "aac": return "AAC"
        case "dts": return "DTS"
        case "truehd": return "TrueHD"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "mov_text": return "Text"
        case "webvtt": return "WebVTT"
        case "hdmv_pgs_subtitle": return "PGS (picture)"
        case "dvd_subtitle": return "VobSub (picture)"
        default: return codec.uppercased()
        }
    }

    private static func channelName(_ channels: Int?) -> String? {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let count?: return "\(count) channels"
        case nil: return nil
        }
    }

    /// The backend's `save-tracks` entry for this track.
    var planEntry: [String: Any] {
        var entry: [String: Any] = [
            "kind": kind.rawValue,
            "language": language,
            "title": title,
            "default": isDefault,
            "forced": isForced,
        ]
        switch source {
        case let .original(index): entry["index"] = index
        case let .file(path): entry["file"] = path
        }
        return entry
    }
}

/// Languages offered for a track: unknown, the app's spoken languages, and any other tag the file already has.
enum TrackLanguage {
    static func options(including current: String) -> [(code: String, name: String)] {
        var options = [(code: "", name: "Unknown")]
        options += SpokenLanguage.all.filter { !$0.code.isEmpty }.map { ($0.code, $0.displayName) }
        if !current.isEmpty, !options.contains(where: { $0.code == current }) {
            options.append((current, Locale.current.localizedString(forLanguageCode: current)?.capitalized ?? current))
        }
        return options
    }

    /// The editor's code for a file's tag: two letters when the app knows the language, else the tag itself.
    static func code(forTag tag: String) -> String {
        guard let code = AudioTrack.languageCode(forTag: tag) else { return "" }
        return SpokenLanguage.all.contains(where: { $0.code == code }) ? code : tag
    }
}

/// Lists a video's audio and subtitle tracks and saves a copy with them removed, reordered, retagged, or with
/// subtitle files added. Like a document: Save writes the changes into the video, Save As writes another file
/// (in the same format) and goes on editing that one. Either way the file is replaced only once the new one is
/// complete, so a failed or cancelled save leaves it as it was.
@MainActor
final class TrackEditorModel: ObservableObject {
    @Published private(set) var videoPath: String?
    // Any change means the last save no longer matches what's shown.
    @Published var audioTracks: [EditableTrack] = [] {
        didSet { lastSavedPath = nil }
    }
    @Published var subtitleTracks: [EditableTrack] = [] {
        didSet { lastSavedPath = nil }
    }
    /// e.g. "HEVC video · 2 attachments"
    @Published private(set) var videoSummary = ""
    /// False when the format can't be edited (only .mp4, .m4v, .mov and .mkv can).
    @Published private(set) var isEditable = true
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var saveProgress: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSavedPath: String?
    /// True when the last save was cancelled.
    @Published private(set) var lastSaveCancelled = false
    /// Set while asking whether to save changes before opening this video.
    @Published var pendingOpen: PendingOpen?

    /// A video to open once the unsaved-changes question is answered.
    struct PendingOpen: Equatable {
        let videoPath: String
        let subtitleFile: String?
        let language: String
    }

    /// The formats tracks can be edited in.
    nonisolated static let editableExtensions = ["mp4", "m4v", "mov", "mkv"]
    /// Subtitle files that can be added.
    nonisolated static let addableSubtitleExtensions = ["srt", "ass", "ssa", "vtt"]

    private let backend = BackendClient()
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var cancelRequested = false
    /// The tracks as last loaded from the file, to tell whether anything changed since.
    private var savedTracks: [EditableTrack] = []

    var videoName: String {
        videoPath.map { ($0 as NSString).lastPathComponent } ?? ""
    }


    /// e.g. "2 audio · 32 subtitles", shown under the pane's title; empty with no video.
    var trackSummary: String {
        guard videoPath != nil, isEditable, !isLoading else { return "" }
        let audio = audioTracks.count == keptAudioCount ? "\(audioTracks.count)" : "\(keptAudioCount) of \(audioTracks.count)"
        let subtitles = subtitleTracks.count == keptSubtitleCount
            ? "\(subtitleTracks.count)"
            : "\(keptSubtitleCount) of \(subtitleTracks.count)"
        return "\(audio) audio · \(subtitles) subtitles"
    }

    var keptAudioCount: Int { audioTracks.filter(\.keep).count }
    var keptSubtitleCount: Int { subtitleTracks.filter(\.keep).count }

    /// A copy with no audio is allowed, but worth pointing out.
    var hasNoAudio: Bool { videoPath != nil && !isLoading && keptAudioCount == 0 }

    /// True when the tracks differ from the file's, so Save has something to write.
    var hasChanges: Bool {
        videoPath != nil && !isLoading && audioTracks + subtitleTracks != savedTracks
    }

    var canSaveAs: Bool { videoPath != nil && isEditable && !isLoading && !isSaving }
    /// Save writes into the video, so it's only offered when there are changes.
    var canSave: Bool { canSaveAs && hasChanges }

    /// The name offered in the save panel, e.g. "Episode 3.edited.mkv".
    var suggestedFileName: String {
        guard let videoPath else { return "" }
        let url = URL(fileURLWithPath: videoPath)
        return "\(url.deletingPathExtension().lastPathComponent).edited.\(url.pathExtension)"
    }

    /// Opens a video, first asking whether to save unsaved changes to the current one (see `pendingOpen`).
    func requestOpen(videoPath path: String, addingSubtitleFile subtitleFile: String? = nil, language: String = "") {
        guard !isSaving else { return }
        let request = PendingOpen(videoPath: path, subtitleFile: subtitleFile, language: language)
        if hasChanges {
            pendingOpen = request
        } else {
            open(videoPath: path, addingSubtitleFile: subtitleFile, language: language)
        }
    }

    /// Answers the unsaved-changes question: save first (then open), open without saving, or cancel.
    func resolvePendingOpen(save shouldSave: Bool?) {
        guard let request = pendingOpen else { return }
        switch shouldSave {
        case true?:
            // Opened once the save succeeds; a failed save keeps the video and its changes.
            save(thenOpen: request)
        case false?:
            pendingOpen = nil
            open(videoPath: request.videoPath, addingSubtitleFile: request.subtitleFile, language: request.language)
        case nil:
            pendingOpen = nil
        }
    }

    /// Opens a video, discarding unsaved changes. `subtitleFile`, when given, is added as the default subtitle
    /// track in `language`. `savedPath` keeps the "Saved" message after reopening a file that was just saved.
    func open(
        videoPath path: String,
        addingSubtitleFile subtitleFile: String? = nil,
        language: String = "",
        savedPath: String? = nil
    ) {
        loadTask?.cancel()
        videoPath = path
        audioTracks = []
        subtitleTracks = []
        savedTracks = []
        videoSummary = ""
        errorMessage = nil
        lastSavedPath = nil
        saveProgress = 0
        let ext = (path as NSString).pathExtension.lowercased()
        isEditable = Self.editableExtensions.contains(ext)
        guard isEditable else {
            errorMessage = "Tracks can only be edited in .mp4, .m4v, .mov and .mkv videos."
            return
        }
        isLoading = true
        loadTask = Task { [weak self, backend] in
            let result: Result<[MediaTrack], Error>
            do {
                result = .success(try await backend.fetchMediaTracks(inputPath: path))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, self.videoPath == path else { return }
            self.isLoading = false
            switch result {
            case let .success(tracks):
                self.load(tracks)
                self.lastSavedPath = savedPath
                if let subtitleFile {
                    self.addSubtitleFile(path: subtitleFile, language: language, makeDefault: true, atTop: true)
                }
            case let .failure(error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Fills the editor from the backend's track list. The tracks are known from here on, so any listing still
    /// running is dropped.
    func load(_ tracks: [MediaTrack]) {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        func editable(_ track: MediaTrack, kind: EditableTrack.Kind) -> EditableTrack {
            EditableTrack(
                kind: kind,
                source: .original(index: track.index),
                codec: track.codec,
                channels: track.channels,
                language: TrackLanguage.code(forTag: track.language),
                title: track.title,
                isDefault: track.default,
                isForced: track.forced
            )
        }
        audioTracks = tracks.filter { $0.kind == "audio" }.map { editable($0, kind: .audio) }
        subtitleTracks = tracks.filter { $0.kind == "subtitle" }.map { editable($0, kind: .subtitle) }
        savedTracks = audioTracks + subtitleTracks

        let videos = tracks.filter { $0.kind == "video" }
        let attachments = tracks.filter { $0.kind == "attachment" }.count
        var parts = videos.map { "\($0.codec.uppercased()) video" }
        if attachments > 0 {
            parts.append(attachments == 1 ? "1 attachment" : "\(attachments) attachments")
        }
        videoSummary = parts.isEmpty ? "No video track" : parts.joined(separator: " · ")
    }

    func addSubtitleFile(path: String, language: String = "", makeDefault: Bool = false, atTop: Bool = false) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard Self.addableSubtitleExtensions.contains(ext) else {
            errorMessage = "Only .srt, .ass, .ssa and .vtt subtitle files can be added."
            return
        }
        var track = EditableTrack(
            kind: .subtitle,
            source: .file(path: path),
            codec: ext == "srt" ? "subrip" : ext,
            channels: nil,
            language: language,
            title: "",
            isDefault: false,
            isForced: false
        )
        if atTop {
            subtitleTracks.insert(track, at: 0)
        } else {
            subtitleTracks.append(track)
        }
        if makeDefault {
            track = subtitleTracks.first(where: { $0.id == track.id }) ?? track
            setDefault(track.id, kind: .subtitle, isOn: true)
        }
    }

    /// Only one track of each kind can be the default, so turning one on turns the others off.
    func setDefault(_ id: EditableTrack.ID, kind: EditableTrack.Kind, isOn: Bool) {
        update(kind) { tracks in
            for i in tracks.indices {
                if tracks[i].id == id {
                    tracks[i].isDefault = isOn
                    if isOn { tracks[i].keep = true }
                } else if isOn {
                    tracks[i].isDefault = false
                }
            }
        }
    }

    func setKeep(_ id: EditableTrack.ID, kind: EditableTrack.Kind, keep: Bool) {
        update(kind) { tracks in
            guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
            tracks[i].keep = keep
            // A track that's left out can't be the one players start with.
            if !keep { tracks[i].isDefault = false }
        }
    }

    func move(_ kind: EditableTrack.Kind, fromOffsets source: IndexSet, toOffset destination: Int) {
        update(kind) { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// Moves a track one place up (-1) or down (+1).
    func move(_ id: EditableTrack.ID, kind: EditableTrack.Kind, by step: Int) {
        update(kind) { tracks in
            guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
            let j = i + step
            guard tracks.indices.contains(j) else { return }
            tracks.swapAt(i, j)
        }
    }

    /// Removes an added subtitle file (the video's own tracks are unticked instead).
    func removeAddedTrack(_ id: EditableTrack.ID) {
        subtitleTracks.removeAll { $0.id == id && $0.isAdded }
    }

    private func update(_ kind: EditableTrack.Kind, _ change: (inout [EditableTrack]) -> Void) {
        switch kind {
        case .audio: change(&audioTracks)
        case .subtitle: change(&subtitleTracks)
        }
    }

    /// The kept tracks in order, as the backend's `save-tracks` plan.
    var plan: [[String: Any]] {
        (audioTracks + subtitleTracks).filter(\.keep).map(\.planEntry)
    }

    func planJSON() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Save: writes the changes into the video itself.
    func save() {
        guard let videoPath, canSave else { return }
        write(to: URL(fileURLWithPath: videoPath), thenOpen: nil)
    }

    private func save(thenOpen request: PendingOpen) {
        guard let videoPath, canSaveAs else {
            pendingOpen = nil
            return
        }
        write(to: URL(fileURLWithPath: videoPath), thenOpen: request)
    }

    /// Save As: writes another file and goes on editing it. Choosing the video's own name is the same as Save.
    func saveAs(to url: URL) {
        guard canSaveAs else { return }
        write(to: url, thenOpen: nil)
    }

    private func write(to url: URL, thenOpen request: PendingOpen?) {
        guard let videoPath else { return }
        let replacesVideo = url.standardizedFileURL.path == URL(fileURLWithPath: videoPath).standardizedFileURL.path
        let json: String
        do {
            json = try planJSON()
        } catch {
            errorMessage = error.localizedDescription
            pendingOpen = nil
            return
        }
        isSaving = true
        saveProgress = 0
        errorMessage = nil
        lastSavedPath = nil
        lastSaveCancelled = false
        cancelRequested = false
        saveTask = Task { [weak self, backend] in
            let (events, continuation) = AsyncStream.makeStream(of: BackendStreamEvent.self)
            let consumer = Task { @MainActor [weak self] in
                for await event in events {
                    self?.apply(event)
                }
            }
            var runError: Error?
            do {
                try await backend.saveTracks(
                    inputPath: videoPath,
                    outputPath: url.path,
                    planJSON: json,
                    replaceOriginal: replacesVideo
                ) { event in
                    continuation.yield(event)
                }
            } catch {
                runError = error
            }
            continuation.finish()
            await consumer.value
            guard let self else { return }
            self.isSaving = false
            self.saveTask = nil
            if let saved = self.lastSavedPath {
                self.pendingOpen = nil
                if let request {
                    self.open(videoPath: request.videoPath, addingSubtitleFile: request.subtitleFile, language: request.language)
                } else {
                    // The saved file's tracks are numbered afresh, so edit it from what's now on disk.
                    self.open(videoPath: saved, savedPath: saved)
                }
                return
            }
            self.pendingOpen = nil
            if self.cancelRequested {
                // The backend reports a cancel as a failed exit; it isn't one.
                self.errorMessage = nil
                self.lastSaveCancelled = true
            } else if let runError, self.errorMessage == nil, !(runError is CancellationError) {
                self.errorMessage = runError.localizedDescription
            }
        }
    }

    func cancelSave() {
        guard isSaving else { return }
        cancelRequested = true
        backend.cancelActiveRun()
    }

    private func apply(_ event: BackendStreamEvent) {
        switch event {
        case let .progress(value):
            saveProgress = min(max(value, 0), 100)
        case let .done(path):
            saveProgress = 100
            lastSavedPath = path
        case let .error(message):
            errorMessage = message
        default:
            break
        }
    }

    // MARK: - Panels

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.editableExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let path = panel.url?.path {
            requestOpen(videoPath: path)
        }
    }

    func chooseSubtitleFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add subtitles"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.addableSubtitleExtensions.compactMap { UTType(filenameExtension: $0) }
        if let videoPath {
            panel.directoryURL = URL(fileURLWithPath: videoPath).deletingLastPathComponent()
        }
        if panel.runModal() == .OK {
            for url in panel.urls {
                addSubtitleFile(path: url.path)
            }
        }
    }

    /// Save As: asks for a name and folder, then saves there.
    func chooseSaveAsLocation() {
        guard let videoPath, canSaveAs else { return }
        let video = URL(fileURLWithPath: videoPath)
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.directoryURL = video.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedFileName
        if let type = UTType(filenameExtension: video.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        if panel.runModal() == .OK, let url = panel.url {
            saveAs(to: url)
        }
    }

    func revealLastSaved() {
        guard let lastSavedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastSavedPath)])
    }
}
