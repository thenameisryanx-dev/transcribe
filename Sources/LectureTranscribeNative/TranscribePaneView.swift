import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct TranscribePaneView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel
    @AppStorage("hasSeenHowToGuide") private var hasSeenHowToGuide = false

    @State private var showingHowToGuide = false
    @State private var howToStepIndex = 0
    @State private var isAudioFileDropTargeted = false
    @State private var audioFileDetails: String?
    @AppStorage("showsRunLog") private var showsRunLog = false

    private var currentHowToStep: HowToStep {
        Self.howToSteps[howToStepIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            if needsAPIKey {
                apiKeyBanner
                    .padding([.horizontal, .top], 20)
                    .howToTarget(.account)
            }

            VStack(spacing: 18) {
                recordingView
                    .howToTarget(.inputOutput)

                if !viewModel.hasTranscribedCurrentRecording {
                    speakerLabelsOption
                        .howToTarget(.options)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .overlay {
                if isAudioFileDropTargeted && !viewModel.isRunning {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(
                            Color.accentColor.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }

            runLog
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .howToTarget(.runLog)
        }
        .navigationTitle("Transcribe")
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModelSelectionPopoverButton(
                    selectedModel: $viewModel.selectedTranscriptionModel,
                    isDisabled: viewModel.isRunning
                )
                .help("Transcription model")
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.requestClearDraft()
                } label: {
                    Label("Clear Draft", systemImage: "xmark.circle")
                }
                .disabled(!viewModel.canClearDraft)
                .help("Clears selected audio, progress, and run log. Keeps run history.")

                // Cancel and Start stay put and enable by state (like Run/Stop in Xcode);
                // once the recording is transcribed, the primary action opens the result.
                Button {
                    viewModel.cancelTranscription()
                } label: {
                    Label("Cancel Run", systemImage: "stop.fill")
                }
                .keyboardShortcut(.cancelAction)
                .disabled(!viewModel.canCancel)
                .help("Stops the active transcription run.")

                if viewModel.hasTranscribedCurrentRecording {
                    Button("Open Transcript") {
                        viewModel.openLatestTranscript()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Open the finished transcript (Return)")
                } else {
                    Button("Start Transcribing") {
                        viewModel.startTranscription()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canStart)
                    .accessibilityLabel("Start transcribing")
                    .help("Transcribe the selected recording (Return)")
                }
            }
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isAudioFileDropTargeted,
            perform: handleAudioFileDrop(providers:)
        )
        .overlayPreferenceValue(HowToTargetPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if showingHowToGuide, proxy.size.width > 120, proxy.size.height > 120 {
                    HowToGuideOverlay(
                        step: currentHowToStep,
                        stepNumber: howToStepIndex + 1,
                        totalSteps: Self.howToSteps.count,
                        highlightRect: spotlightRect(
                            for: currentHowToStep.target,
                            anchors: anchors,
                            proxy: proxy
                        ),
                        onBack: previousHowToStep,
                        onNext: nextHowToStep,
                        onClose: closeHowToGuide
                    )
                }
            }
        }
        .confirmationDialog(
            "Clear current draft?",
            isPresented: $viewModel.showingClearDraftConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Draft") {
                viewModel.clearDraft()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the selected audio file, progress, and run log. It does not remove any run history.")
        }
        .onAppear {
            if handleHowToGuideRequestIfNeeded() {
                hasSeenHowToGuide = true
                return
            }
            guard !hasSeenHowToGuide else { return }
            hasSeenHowToGuide = true
            startHowToGuide()
        }
        .onChange(of: viewModel.howToGuideRequestToken) { _ in
            if handleHowToGuideRequestIfNeeded() {
                hasSeenHowToGuide = true
            }
        }
    }

    private var trimmedAudioPath: String {
        viewModel.audioFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var needsAPIKey: Bool {
        let status = viewModel.apiKeyStatusText.lowercased()
        return status.contains("required") || status.contains("unknown")
    }

    private var windowSubtitle: String {
        if viewModel.isRunning {
            return "\(viewModel.statusText) – \(viewModel.progressLabel)"
        }
        return viewModel.statusText
    }

    private var apiKeyBanner: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add your OpenAI API key")
                        .font(.headline)
                    Text("Transcription needs a key. You can also manage it in Settings.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Set API Key…") {
                    viewModel.presentAPIKeySheet()
                }
                .disabled(viewModel.isRunning)
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var recordingView: some View {
        if trimmedAudioPath.isEmpty {
            EmptyStateView(
                title: "Drop a Lecture Recording",
                systemImage: "waveform.badge.plus",
                description: "Drag an audio or video file here, or choose one from your Mac."
            ) {
                Button("Choose File…", action: viewModel.browseAudioFile)
                    .disabled(viewModel.isRunning)
            }
        } else {
            selectedRecordingView
        }
    }

    private var selectedRecordingView: some View {
        let url = URL(fileURLWithPath: trimmedAudioPath)
        let outputFolder = (viewModel.outputFolderPath as NSString).abbreviatingWithTildeInPath

        return VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: trimmedAudioPath))
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let audioFileDetails {
                    Text(audioFileDetails)
                        .foregroundStyle(.secondary)
                }
            }
            .help(trimmedAudioPath)

            if viewModel.hasTranscribedCurrentRecording {
                completedRunSummary
            } else if viewModel.isRunning || viewModel.progressValue > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: viewModel.progressValue, total: 100.0)
                    HStack {
                        Text(viewModel.statusText)
                        Spacer()
                        Text(viewModel.progressLabel)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .frame(width: 360)
                .padding(.top, 4)
            } else {
                Button("Choose Different File…", action: viewModel.browseAudioFile)
                    .disabled(viewModel.isRunning)
            }

            if !viewModel.hasTranscribedCurrentRecording {
                Text("Transcripts are saved to \(outputFolder).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 520)
        .task(id: trimmedAudioPath) {
            audioFileDetails = await Self.loadAudioFileDetails(for: url)
        }
    }

    private var completedRunSummary: some View {
        VStack(spacing: 12) {
            Label {
                Text("Transcription Complete")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.headline)

            if let latestOutputPath = viewModel.latestOutputPath {
                Text((latestOutputPath as NSString).abbreviatingWithTildeInPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button("Show in Finder") {
                    viewModel.revealLatestTranscript()
                }
                Button("Choose Another File…", action: viewModel.browseAudioFile)
            }
        }
        .padding(.top, 4)
    }

    private var speakerLabelsOption: some View {
        VStack(spacing: 4) {
            Toggle("Add speaker labels (diarize)", isOn: $viewModel.diarizeEnabled)
                .toggleStyle(.checkbox)
                .disabled(viewModel.isRunning || !viewModel.isDiarizationAvailable)
                .accessibilityLabel("Add speaker labels")
            if !viewModel.isDiarizationAvailable {
                Text("Unavailable for \(viewModel.selectedTranscriptionModel.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runLog: some View {
        DisclosureGroup("Run Log", isExpanded: $showsRunLog) {
            ScrollView {
                Text(viewModel.logText.isEmpty ? "No log output yet." : viewModel.logText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.top, 6)
        }
    }

    private static func loadAudioFileDetails(for url: URL) async -> String? {
        var parts: [String] = []
        let folder = url.deletingLastPathComponent().path
        parts.append((folder as NSString).abbreviatingWithTildeInPath)

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }

        if let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric, duration.seconds > 0 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = duration.seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
            formatter.unitsStyle = .abbreviated
            if let text = formatter.string(from: duration.seconds) {
                parts.append(text)
            }
        }

        return parts.joined(separator: " · ")
    }

    /// Returns `nil` when the target isn't laid out in the pane content
    /// (toolbar items, or the API key banner once a key is set).
    private func spotlightRect(
        for target: HowToTarget,
        anchors: [HowToTarget: [Anchor<CGRect>]],
        proxy: GeometryProxy
    ) -> CGRect? {
        guard let targetAnchors = anchors[target], !targetAnchors.isEmpty else {
            return nil
        }

        let unionRect = targetAnchors
            .map { proxy[$0] }
            .reduce(CGRect.null) { $0.union($1) }
        let rawRect = unionRect.insetBy(dx: -10, dy: -10)
        return clampedSpotlightRect(rawRect, in: proxy.size, for: target)
    }

    private func clampedSpotlightRect(_ rect: CGRect, in size: CGSize, for target: HowToTarget) -> CGRect {
        let minimumSize: CGSize
        switch target {
        case .options:
            minimumSize = CGSize(width: 160, height: 60)
        case .startButton:
            minimumSize = CGSize(width: 88, height: 30)
        default:
            minimumSize = CGSize(width: 140, height: 40)
        }

        let availableWidth = max(80, size.width - 32)
        let availableHeight = max(60, size.height - 32)
        let maximumSize = CGSize(width: availableWidth, height: availableHeight)

        let width = min(max(rect.width.isFinite ? rect.width : 220, minimumSize.width), maximumSize.width)
        let height = min(max(rect.height.isFinite ? rect.height : 120, minimumSize.height), maximumSize.height)

        let minX: CGFloat = 16
        let maxX = max(minX, size.width - width - 16)
        let minY: CGFloat = 16
        let maxY = max(minY, size.height - height - 16)

        let fallbackX = (size.width - width) / 2
        let fallbackY = (size.height - height) / 2
        let x = min(max(rect.origin.x.isFinite ? rect.origin.x : fallbackX, minX), maxX)
        let y = min(max(rect.origin.y.isFinite ? rect.origin.y : fallbackY, minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func startHowToGuide() {
        howToStepIndex = 0
        showingHowToGuide = true
    }

    private func previousHowToStep() {
        guard howToStepIndex > 0 else { return }
        howToStepIndex -= 1
    }

    private func nextHowToStep() {
        if howToStepIndex >= Self.howToSteps.count - 1 {
            closeHowToGuide()
            return
        }

        howToStepIndex += 1
    }

    private func closeHowToGuide() {
        showingHowToGuide = false
    }

    @discardableResult
    private func handleHowToGuideRequestIfNeeded() -> Bool {
        guard viewModel.consumeHowToGuideRequestIfNeeded() else { return false }
        startHowToGuide()
        return true
    }

    private static let howToSteps: [HowToStep] = [
        HowToStep(
            target: .account,
            title: "1) Add your API key",
            message: "This app requires an OpenAI API key to work. Use Set API Key (also in Settings) first, then you can run transcriptions."
        ),
        HowToStep(
            target: .inputOutput,
            title: "2) Choose a recording",
            message: "Drop a lecture recording into the window or click Choose File. Transcripts are saved to the output folder set in Settings."
        ),
        HowToStep(
            target: .options,
            title: "3) Choose options",
            message: "Enable speaker labels when your recording includes multiple speakers. Pick the transcription model from the toolbar."
        ),
        HowToStep(
            target: .startButton,
            title: "4) Start transcription",
            message: "Click Start Transcribing in the toolbar. Progress appears here and in the window title."
        ),
        HowToStep(
            target: .runLog,
            title: "5) Review results",
            message: "Expand Run Log to watch progress. Finished transcripts are listed in Runs."
        ),
    ]

    private func handleAudioFileDrop(providers: [NSItemProvider]) -> Bool {
        guard !viewModel.isRunning else { return false }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            if let error {
                Task { @MainActor in
                    viewModel.reportDroppedAudioFileReadFailure(details: error.localizedDescription)
                }
                return
            }

            guard let droppedURL = Self.droppedFileURL(from: item) else {
                Task { @MainActor in
                    viewModel.reportDroppedAudioFileReadFailure()
                }
                return
            }

            Task { @MainActor in
                viewModel.loadDroppedAudioFile(droppedURL)
            }
        }

        return true
    }

    nonisolated private static func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }
            if let text = String(data: data, encoding: .utf8) {
                return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        if let text = item as? String {
            return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let text = item as? NSString {
            return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }
}

private struct ModelSelectionPopoverButton: View {
    @Binding var selectedModel: TranscriptionModel
    let isDisabled: Bool

    @State private var showingPopover = false
    @State private var hoveredModelInPopover: TranscriptionModel?

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selectedModel.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .disabled(isDisabled)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription Model")
                    .font(.headline)
                    .padding(.bottom, 2)

                ForEach(TranscriptionModel.allCases) { model in
                    Button {
                        selectedModel = model
                        showingPopover = false
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .foregroundStyle(.primary)
                                Text(model.hoverDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 10)
                            if selectedModel == model {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    {
                                        if selectedModel == model {
                                            return hoveredModelInPopover == model
                                                ? Color.accentColor.opacity(0.20)
                                                : Color.accentColor.opacity(0.14)
                                        }
                                        return hoveredModelInPopover == model
                                            ? Color.secondary.opacity(0.14)
                                            : Color.clear
                                    }()
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering {
                            hoveredModelInPopover = model
                        } else if hoveredModelInPopover == model {
                            hoveredModelInPopover = nil
                        }
                    }
                }
            }
            .frame(width: 320, alignment: .leading)
            .padding(12)
        }
    }
}

struct APIKeySheetView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set OpenAI API Key")
                .font(.title3.weight(.semibold))

            Text("Enter a key that starts with \"sk-\". You can save it securely in macOS Keychain.")
                .foregroundStyle(.secondary)

            SecureField("sk-...", text: $viewModel.pendingAPIKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("OpenAI API key")

            Toggle("Save in system keychain", isOn: $viewModel.saveAPIKeyToKeychain)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.dismissAPIKeySheet()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    viewModel.submitAPIKey()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private enum HowToTarget: Hashable {
    case account
    case inputOutput
    case options
    case startButton
    case runLog
}

private struct HowToStep {
    let target: HowToTarget
    let title: String
    let message: String
}

// Inside a Form, a modifier on a Section is applied to each of its rows,
// so every target collects all of its anchors and the spotlight unions them.
private struct HowToTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [HowToTarget: [Anchor<CGRect>]] = [:]

    static func reduce(value: inout [HowToTarget: [Anchor<CGRect>]], nextValue: () -> [HowToTarget: [Anchor<CGRect>]]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}

private extension View {
    func howToTarget(_ target: HowToTarget) -> some View {
        anchorPreference(key: HowToTargetPreferenceKey.self, value: .bounds) { [target: [$0]] }
    }
}

private struct SpotlightShape: Shape {
    let holeRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        if !holeRect.isNull {
            path.addRoundedRect(in: holeRect, cornerSize: CGSize(width: 14, height: 14))
        }
        return path
    }
}

private struct HowToGuideOverlay: View {
    let step: HowToStep
    let stepNumber: Int
    let totalSteps: Int
    let highlightRect: CGRect?
    let onBack: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = instructionLayout(in: proxy.size, highlightRect: highlightRect ?? .null)

            ZStack {
                SpotlightShape(holeRect: highlightRect ?? .null)
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))

                // Allow users to advance the tutorial by clicking anywhere.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onNext()
                    }

                if let highlightRect {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.95), lineWidth: 2)
                        .frame(width: max(0, highlightRect.width), height: max(0, highlightRect.height))
                        .position(x: highlightRect.midX, y: highlightRect.midY)
                        .shadow(color: .black.opacity(0.3), radius: 16)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("How to Use Lecture Transcribe")
                        .font(.headline)
                    Text(step.title)
                        .font(.title3.weight(.semibold))
                    Text(step.message)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Text("Step \(stepNumber) of \(totalSteps)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Close", action: onClose)
                            .buttonStyle(.bordered)
                        Button("Back", action: onBack)
                            .buttonStyle(.bordered)
                            .disabled(stepNumber <= 1)
                        Button(stepNumber == totalSteps ? "Done" : "Next", action: onNext)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .frame(width: layout.cardWidth, alignment: .leading)
                .foregroundStyle(.primary)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
                .position(layout.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Getting started guide")
    }

    private func instructionLayout(in size: CGSize, highlightRect: CGRect) -> (cardWidth: CGFloat, center: CGPoint) {
        let horizontalInset: CGFloat = 16
        let verticalInset: CGFloat = 16
        let gap: CGFloat = 14
        let estimatedCardHeight: CGFloat = 210
        let preferredWidth = min(440, max(280, size.width * 0.36))
        let cardWidth = min(preferredWidth, max(220, size.width - (horizontalInset * 2)))

        let rightSpace = size.width - highlightRect.maxX - horizontalInset
        let leftSpace = highlightRect.minX - horizontalInset
        let belowSpace = size.height - highlightRect.maxY - verticalInset
        let aboveSpace = highlightRect.minY - verticalInset

        var center = CGPoint(
            x: size.width / 2,
            y: size.height - verticalInset - (estimatedCardHeight / 2)
        )

        if highlightRect.isNull {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
        } else if rightSpace >= cardWidth + gap {
            center = CGPoint(
                x: highlightRect.maxX + gap + (cardWidth / 2),
                y: highlightRect.midY
            )
        } else if leftSpace >= cardWidth + gap {
            center = CGPoint(
                x: highlightRect.minX - gap - (cardWidth / 2),
                y: highlightRect.midY
            )
        } else if belowSpace >= estimatedCardHeight + gap {
            center = CGPoint(
                x: highlightRect.midX,
                y: highlightRect.maxY + gap + (estimatedCardHeight / 2)
            )
        } else if aboveSpace >= estimatedCardHeight + gap {
            center = CGPoint(
                x: highlightRect.midX,
                y: highlightRect.minY - gap - (estimatedCardHeight / 2)
            )
        }

        let minX = horizontalInset + (cardWidth / 2)
        let maxX = max(minX, size.width - horizontalInset - (cardWidth / 2))
        let minY = verticalInset + (estimatedCardHeight / 2)
        let maxY = max(minY, size.height - verticalInset - (estimatedCardHeight / 2))

        center.x = min(max(center.x, minX), maxX)
        center.y = min(max(center.y, minY), maxY)

        return (cardWidth, center)
    }
}

/// The system empty-state layout (`ContentUnavailableView` on macOS 14 and later).
struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            } actions: {
                actions()
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(description)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                actions()
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, systemImage: String, description: String) {
        self.init(title: title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
