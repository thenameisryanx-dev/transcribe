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
                .background(ReorderDragTuning())
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

/// Tunes the list's table for dragging rows to reorder them:
/// - The table opens a gap where the row will land and slides the other rows aside as the drag moves (as Finder's
///   sidebar and Safari's tabs do), instead of drawing an insertion line and jumping on drop.
/// - Holding a row near the top or bottom edge scrolls the list, faster the closer it is to the edge. The table's own
///   autoscroll crawls (about one row every two seconds), which makes long lists impractical to reorder.
private struct ReorderDragTuning: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Locator() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Finds the table it's laid out in. Rows come and go as the list scrolls, so the tuning lives on the table.
    private final class Locator: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                var view = self?.superview
                while let current = view, !(current is NSTableView) { view = current.superview }
                if let table = view as? NSTableView {
                    EdgeAutoscroller.install(on: table)
                }
            }
        }
    }

    @MainActor
    private final class EdgeAutoscroller {
        private static var key = 0

        /// The band along each edge where holding a row scrolls the list, in points. It's about as tall as the
        /// sticky section header, so hovering over the first or last visible row to drop there doesn't scroll.
        private static let edgeBand: CGFloat = 32
        /// How far past an edge the pointer reaches full speed, in points.
        private static let overshoot: CGFloat = 48
        /// Scrolling speeds in points per second. Scrolling starts at a clear pace rather than a crawl: a crawl moves
        /// rows under the pointer a pixel at a time, so the drop gap keeps jumping between rows.
        private static let minSpeed: CGFloat = 320
        private static let maxSpeed: CGFloat = 1800

        private weak var table: NSTableView?
        // Only touched on the main thread; deinit is nonisolated.
        nonisolated(unsafe) private var mouseDownMonitor: Any?
        nonisolated(unsafe) private var timer: Timer?
        private var dragPasteboardCount = 0
        private var lastTick: CFTimeInterval = 0

        static func install(on table: NSTableView) {
            DropValidationGuard.install(on: table)
            guard objc_getAssociatedObject(table, &key) == nil else { return }
            objc_setAssociatedObject(table, &key, EdgeAutoscroller(table: table), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        private init(table: NSTableView) {
            self.table = table
            // A press in the table may start a row drag. Watch the pointer until the button comes up; a drag
            // session runs its own event loop, so a timer in the common modes is what keeps firing during it.
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.mouseDown(event) }
                return event
            }
        }

        deinit {
            if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
            timer?.invalidate()
        }

        private func mouseDown(_ event: NSEvent) {
            guard let table, event.window === table.window, let clipView = table.enclosingScrollView?.contentView,
                  clipView.bounds.contains(clipView.convert(event.locationInWindow, from: nil))
            else { return }
            // Before any drag starts, in case the list has replaced its data source since.
            DropValidationGuard.install(on: table)
            // A drag session writes to the drag pasteboard as it begins; until then this is a click.
            dragPasteboardCount = NSPasteboard(name: .drag).changeCount
            lastTick = CACurrentMediaTime()
            timer?.invalidate()
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            let now = CACurrentMediaTime()
            let elapsed = min(now - lastTick, 1.0 / 30.0)
            lastTick = now

            guard NSEvent.pressedMouseButtons & 1 != 0, let table, let window = table.window,
                  let scrollView = table.enclosingScrollView, let documentView = scrollView.documentView
            else {
                timer?.invalidate()
                timer = nil
                return
            }
            guard NSPasteboard(name: .drag).changeCount != dragPasteboardCount else { return }

            let clipView = scrollView.contentView
            // The real pointer: during a drag session the window's own event stream lags behind it.
            let pointer = clipView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let visible = clipView.bounds
            let insets = scrollView.contentInsets
            let top = visible.minY + insets.top
            let bottom = visible.maxY - insets.bottom
            let band = min(Self.edgeBand, (bottom - top) / 4)
            // Only while the drag is over the list (or just past its top and bottom edges).
            guard pointer.x >= visible.minX, pointer.x <= visible.maxX,
                  pointer.y >= top - Self.overshoot, pointer.y <= bottom + Self.overshoot
            else { return }

            // Speed eases in from the inner edge of the band to full speed just past the edge.
            let direction: CGFloat
            let distance: CGFloat
            if pointer.y < top + band {
                direction = -1
                distance = top + band - pointer.y
            } else if pointer.y > bottom - band {
                direction = 1
                distance = pointer.y - (bottom - band)
            } else {
                return
            }
            let depth = min(distance / (band + Self.overshoot), 1)
            let speed = Self.minSpeed + (Self.maxSpeed - Self.minSpeed) * depth * depth

            let minY = -insets.top
            let maxY = max(minY, documentView.frame.height - visible.height + insets.bottom)
            // Whole pixels, so rows don't shimmer as they move.
            let scale = window.backingScaleFactor
            let step = (visible.minY + direction * speed * CGFloat(elapsed)) * scale
            let y = min(max(step.rounded() / scale, minY), maxY)
            guard y != visible.minY else { return }
            clipView.scroll(to: NSPoint(x: visible.minX, y: y))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    /// Turns on the table's gap feedback, which is only safe behind this guard. When a drag leaves a gap-style
    /// outline view, AppKit asks its data source to validate one more drop, at child index -2; SwiftUI's list then
    /// looks up row -2 and crashes. The guard refuses those itself and passes everything else through to SwiftUI's
    /// data source unchanged.
    @MainActor
    private final class DropValidationGuard: NSObject, NSOutlineViewDataSource {
        private static var key = 0

        private weak var original: (NSObject & NSOutlineViewDataSource)?

        private init(original: NSObject & NSOutlineViewDataSource) {
            self.original = original
        }

        static func install(on table: NSTableView) {
            guard let outline = table as? NSOutlineView else { return }
            // The gap animation moves a floating section header along with the rows, so the sticky header bar
            // would keep sliding down into the list and snapping back while a row is dragged. Headers scroll with
            // their rows instead.
            outline.floatsGroupRows = false
            if outline.dataSource is DropValidationGuard { return }
            guard let original = outline.dataSource as? (NSObject & NSOutlineViewDataSource) else {
                // Without the guard, keep the insertion line (and floating headers) rather than risk the crash.
                outline.draggingDestinationFeedbackStyle = .regular
                outline.floatsGroupRows = true
                return
            }
            let guardian = DropValidationGuard(original: original)
            // The outline view doesn't retain its data source.
            objc_setAssociatedObject(outline, &key, guardian, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            outline.dataSource = guardian
            outline.draggingDestinationFeedbackStyle = .gap
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            // Reordering always proposes a gap between rows (index 0 or more). Leaving the list proposes -2.
            guard index >= 0 else { return [] }
            return original?.outlineView?(
                outlineView, validateDrop: info, proposedItem: item, proposedChildIndex: index
            ) ?? []
        }
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
