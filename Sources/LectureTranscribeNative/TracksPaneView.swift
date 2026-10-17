import SwiftUI
import UniformTypeIdentifiers

/// Shows a video's audio and subtitle tracks so they can be removed, reordered, retagged, or added to.
/// Save writes the changes into the video; Save As writes another file.
struct TracksPaneView: View {
    @ObservedObject var editor: TrackEditorModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if editor.videoPath == nil {
                emptyState
            } else {
                trackList
                Divider()
                saveBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .overlay {
            if isDropTargeted && !editor.isSaving {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
        .navigationTitle("Tracks")
        .navigationSubtitle(editor.trackSummary)
        .toolbar {
            // Save is the pane's one primary action, at the trailing edge, with Save As beside it; choosing a video
            // lives next to its name and in the File menu.
            ToolbarItem(placement: .primaryAction) {
                Button("Save As…", action: editor.chooseSaveAsLocation)
                    .disabled(!editor.canSaveAs)
                    .help("Save these tracks as a new video file, and keep this one as it is (⇧⌘S)")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save", action: editor.save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.canSave)
                    .help(editor.hasChanges
                        ? "Save these changes into the video (⌘S)"
                        : "No changes to save")
            }
        }
        .confirmationDialog(
            "Do you want to save the changes to “\(editor.videoName)”?",
            isPresented: Binding(
                get: { editor.pendingOpen != nil && !editor.isSaving },
                set: { if !$0 && !editor.isSaving { editor.resolvePendingOpen(save: nil) } }
            )
        ) {
            Button("Save") { editor.resolvePendingOpen(save: true) }
            Button("Don't Save", role: .destructive) { editor.resolvePendingOpen(save: false) }
            Button("Cancel", role: .cancel) { editor.resolvePendingOpen(save: nil) }
        } message: {
            Text("Your changes to its tracks will be lost if you don't save them.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Choose a video, or drop one here")
                .font(.title3)
            Text("See its audio and subtitle tracks, remove or reorder them, pick which ones play first, "
                + "and add subtitle files. Save writes the changes into the video; Save As makes a new file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Choose Video…", action: editor.chooseVideo)
                .controlSize(.large)
                .help("Choose a video (⌘O)")
            Text("Works with .mp4, .m4v, .mov and .mkv videos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackList: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    if let videoPath = editor.videoPath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: videoPath))
                            .resizable()
                            .frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(editor.videoName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(editor.videoPath ?? "")
                        if !editor.videoSummary.isEmpty {
                            Text("\(editor.videoSummary) · kept as is")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if editor.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Choose Different Video…", action: editor.chooseVideo)
                        .disabled(editor.isSaving)
                        .help("Open another video in Tracks (⌘O)")
                }
                if let error = editor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            if editor.isEditable && !editor.isLoading {
                Section {
                    ForEach($editor.audioTracks) { $track in
                        TrackRow(track: $track, editor: editor, position: position(of: track, in: editor.audioTracks))
                    }
                    .onMove { editor.move(.audio, fromOffsets: $0, toOffset: $1) }
                    if editor.audioTracks.isEmpty {
                        Text("No audio tracks").foregroundStyle(.secondary)
                    }
                } header: {
                    sectionHeader("Audio", kept: editor.keptAudioCount, total: editor.audioTracks.count)
                } footer: {
                    if editor.hasNoAudio {
                        Label("The copy will have no sound.", systemImage: "speaker.slash")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ForEach($editor.subtitleTracks) { $track in
                        TrackRow(track: $track, editor: editor, position: position(of: track, in: editor.subtitleTracks))
                    }
                    .onMove { editor.move(.subtitle, fromOffsets: $0, toOffset: $1) }
                    if editor.subtitleTracks.isEmpty {
                        Text("No subtitle tracks").foregroundStyle(.secondary)
                    }
                    Button {
                        editor.chooseSubtitleFiles()
                    } label: {
                        Label("Add Subtitles…", systemImage: "plus")
                    }
                    .disabled(editor.isSaving)
                } header: {
                    sectionHeader("Subtitles", kept: editor.keptSubtitleCount, total: editor.subtitleTracks.count)
                } footer: {
                    Text("Drag to reorder. Players list tracks in this order and start with the Default one. "
                        + "QuickTime Player may show no subtitles at all when a video has dozens of subtitle tracks.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(editor.isSaving)
    }

    private func position(of track: EditableTrack, in tracks: [EditableTrack]) -> TrackRow.Position {
        let index = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        return TrackRow.Position(isFirst: index == 0, isLast: index == tracks.count - 1)
    }

    private func sectionHeader(_ title: String, kept: Int, total: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            if total > 0 {
                Text(kept == total ? "\(total) kept" : "\(kept) of \(total) kept")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            if editor.isSaving {
                ProgressView(value: editor.saveProgress, total: 100)
                    .frame(maxWidth: 260)
                Text("Saving… \(Int(editor.saveProgress))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: editor.cancelSave)
                    .keyboardShortcut(.cancelAction)
            } else if let saved = editor.lastSavedPath {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved \((saved as NSString).lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show in Finder", action: editor.revealLastSaved)
            } else {
                Text(editor.lastSaveCancelled
                    ? "Save cancelled. The video wasn't changed."
                    : editor.hasChanges
                        ? "Unsaved changes. Save writes them into the video; Save As makes a new file."
                        : "Video and audio are copied without re-encoding when you save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !editor.isSaving,
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            guard let url else { return }
            Task { @MainActor in
                let ext = url.pathExtension.lowercased()
                if TrackEditorModel.addableSubtitleExtensions.contains(ext), editor.videoPath != nil {
                    editor.addSubtitleFile(path: url.path)
                } else {
                    editor.requestOpen(videoPath: url.path)
                }
            }
        }
        return true
    }
}

/// One audio or subtitle track: keep checkbox, language, title, Default (and Forced for subtitles), and moving.
private struct TrackRow: View {
    struct Position {
        let isFirst: Bool
        let isLast: Bool
    }

    @Binding var track: EditableTrack
    @ObservedObject var editor: TrackEditorModel
    let position: Position

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")

            Toggle("Keep", isOn: Binding(
                get: { track.keep },
                set: { editor.setKeep(track.id, kind: track.kind, keep: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(track.keep ? "Kept in the copy. Untick to leave it out." : "Left out of the copy.")

            VStack(alignment: .leading, spacing: 6) {
                Text(track.sourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("Language", selection: $track.language) {
                        ForEach(TrackLanguage.options(including: track.language), id: \.code) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    TextField("Title (optional)", text: $track.title)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }
            .opacity(track.keep ? 1 : 0.45)

            Spacer()

            Toggle("Default", isOn: Binding(
                get: { track.isDefault },
                set: { editor.setDefault(track.id, kind: track.kind, isOn: $0) }
            ))
            .toggleStyle(.checkbox)
            .help("Players start with the default track. Only one of each kind can be the default.")

            if track.kind == .subtitle {
                Toggle("Forced", isOn: $track.isForced)
                    .toggleStyle(.checkbox)
                    .help("Forced subtitles only cover foreign-language lines and signs, and players show them even with subtitles off.")
            }

            HStack(spacing: 2) {
                Button {
                    editor.move(track.id, kind: track.kind, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(position.isFirst)
                .help("Move up")
                Button {
                    editor.move(track.id, kind: track.kind, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(position.isLast)
                .help("Move down")
            }
            .buttonStyle(.borderless)

            if track.isAdded {
                Button {
                    editor.removeAddedTrack(track.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this subtitle file from the list")
            }
        }
        .padding(.vertical, 4)
    }
}

/// File menu commands for the Tracks pane, so its toolbar actions and opening a video are also in the menu bar.
/// They always show, and are disabled when they don't apply.
struct TrackCommands: Commands {
    @ObservedObject var editor: TrackEditorModel
    let isShowingTracks: Bool
    let showTracks: () -> Void

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Video in Tracks…") {
                showTracks()
                editor.chooseVideo()
            }
            .keyboardShortcut("o")
            .disabled(editor.isSaving)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save", action: editor.save)
                .keyboardShortcut("s")
                .disabled(!isShowingTracks || !editor.canSave)
            Button("Save As…", action: editor.chooseSaveAsLocation)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!isShowingTracks || !editor.canSaveAs)
        }
    }
}
