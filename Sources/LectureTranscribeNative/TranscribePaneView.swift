import AppKit
import SwiftUI

struct TranscribePaneView: View {
    @EnvironmentObject private var viewModel: TranscribeViewModel
    @AppStorage("hasSeenHowToGuide") private var hasSeenHowToGuide = false

    @State private var showingHowToGuide = false
    @State private var howToStepIndex = 0

    private var currentHowToStep: HowToStep {
        Self.howToSteps[howToStepIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lecture Transcribe")
                            .font(.largeTitle.weight(.semibold))
                        Text("Fast transcripts with optional speaker labeling.")
                            .foregroundStyle(.secondary)
                    }

                    GroupBox("Account") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API Key")
                                .font(.subheadline.weight(.semibold))
                            HStack(spacing: 12) {
                                Text(viewModel.apiKeyStatusText)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Button("Set API Key…") {
                                    viewModel.presentAPIKeySheet()
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isRunning)
                            }
                        }
                    }
                    .howToTarget(.account)

                    GroupBox("Input & Output") {
                        VStack(alignment: .leading, spacing: 14) {
                            labeledInputRow(
                                title: "Audio File",
                                placeholder: "Choose an audio file",
                                text: $viewModel.audioFilePath,
                                action: viewModel.browseAudioFile
                            )

                            labeledInputRow(
                                title: "Output Folder",
                                placeholder: "Choose output folder",
                                text: $viewModel.outputFolderPath,
                                action: viewModel.browseOutputFolder
                            )
                        }
                    }
                    .howToTarget(.inputOutput)

                    GroupBox("Options") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Add speaker labels (diarize)", isOn: $viewModel.diarizeEnabled)
                                .disabled(viewModel.isRunning || !viewModel.isDiarizationAvailable)
                                .accessibilityLabel("Add speaker labels")
                            if !viewModel.isDiarizationAvailable {
                                Text("Unavailable for \(viewModel.selectedTranscriptionModel.displayName).")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .howToTarget(.options)

                    GroupBox("Run Log") {
                        ScrollView {
                            Text(viewModel.logText.isEmpty ? "No log output yet." : viewModel.logText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                        .frame(minHeight: 220)
                        .howToTarget(.runLog)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 18)
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                Button("Start Transcribing") {
                    viewModel.startTranscription()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canStart)
                .accessibilityLabel("Start transcribing")
                .howToTarget(.startButton)

                Button("Cancel Run") {
                    viewModel.cancelTranscription()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .disabled(!viewModel.canCancel)
                .help("Stops the active transcription run.")

                Button {
                    viewModel.requestClearDraft()
                } label: {
                    Label("Clear Draft", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canClearDraft)
                .help("Clears selected audio, progress, and run log. Keeps run history.")

                ModelSelectionPopoverButton(
                    selectedModel: $viewModel.selectedTranscriptionModel,
                    isDisabled: viewModel.isRunning
                )

                Spacer(minLength: 18)

                VStack(alignment: .trailing, spacing: 6) {
                    ProgressView(value: viewModel.progressValue, total: 100.0)
                        .frame(width: 220)
                    HStack(spacing: 8) {
                        Text(viewModel.progressLabel)
                            .monospacedDigit()
                        Text(viewModel.statusText)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
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
        .sheet(isPresented: $viewModel.showingAPIKeySheet) {
            APIKeySheetView()
                .environmentObject(viewModel)
                .frame(width: 420)
                .padding(20)
        }
        .alert("Lecture Transcribe", isPresented: $viewModel.showingErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
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

    @ViewBuilder
    private func labeledInputRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isRunning)
                Button("Browse…", action: action)
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isRunning)
            }
        }
    }

    private func spotlightRect(
        for target: HowToTarget,
        anchors: [HowToTarget: Anchor<CGRect>],
        proxy: GeometryProxy
    ) -> CGRect {
        let rawRect: CGRect
        guard let anchor = anchors[target] else {
            rawRect = CGRect(
                x: max(20, (proxy.size.width - 360) / 2),
                y: max(20, (proxy.size.height - 160) / 2),
                width: min(360, max(200, proxy.size.width - 40)),
                height: 160
            )
            return clampedSpotlightRect(rawRect, in: proxy.size, for: target)
        }

        let padding: CGFloat
        switch target {
        case .runLog:
            padding = 2
        case .options, .startButton:
            padding = 6
        default:
            padding = 10
        }

        let anchoredRect = proxy[anchor].insetBy(dx: -padding, dy: -padding)
        if target == .runLog {
            // GroupBox styling can include the section label/header in bounds;
            // trim to keep spotlight focused on the log content viewport.
            let horizontalTrim: CGFloat = 2
            let topTrim: CGFloat = 24
            let bottomTrim: CGFloat = 4
            let sideExpansion: CGFloat = 8
            let bottomExpansion: CGFloat = 8
            let baseHeight = max(120, anchoredRect.height - topTrim - bottomTrim)
            let topLift = baseHeight / 4
            let topEdge = anchoredRect.minY + topTrim - topLift
            rawRect = CGRect(
                x: anchoredRect.minX + horizontalTrim - sideExpansion,
                y: topEdge,
                width: max(120, anchoredRect.width - (horizontalTrim * 2) + (sideExpansion * 2)),
                height: baseHeight + topLift + bottomExpansion
            )
        } else if target == .startButton {
            // Keep left/bottom fixed and nudge top/right inward.
            let rightInset: CGFloat = 2
            let topInset: CGFloat = 4
            let adjustedWidth = max(88, anchoredRect.width - rightInset)
            let adjustedHeight = max(30, anchoredRect.height - topInset)
            rawRect = CGRect(
                x: anchoredRect.minX,
                y: anchoredRect.maxY - adjustedHeight,
                width: adjustedWidth,
                height: adjustedHeight
            )
        } else {
            rawRect = anchoredRect
        }
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
            minimumSize = CGSize(width: 140, height: 100)
        }

        let availableWidth = max(80, size.width - 32)
        let availableHeight = max(60, size.height - 32)
        let maximumSize: CGSize
        switch target {
        case .runLog:
            maximumSize = CGSize(
                width: min(780, availableWidth),
                height: min(252, availableHeight)
            )
        default:
            maximumSize = CGSize(width: availableWidth, height: availableHeight)
        }

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
            message: "This app requires an OpenAI API key to work. Use Set API Key first, then you can run transcriptions."
        ),
        HowToStep(
            target: .inputOutput,
            title: "2) Select audio and output",
            message: "Pick the lecture audio file and choose where transcript files should be written."
        ),
        HowToStep(
            target: .options,
            title: "3) Choose options",
            message: "Enable speaker labels when your recording includes multiple speakers and you want separated dialogue."
        ),
        HowToStep(
            target: .startButton,
            title: "4) Start transcription",
            message: "Click Start Transcribing to run the selected audio file with your current options."
        ),
        HowToStep(
            target: .runLog,
            title: "5) Review results",
            message: "Watch progress and logs here. Use Open Output Folder to quickly access your generated transcript."
        ),
    ]
}

private struct ModelSelectionPopoverButton: View {
    @Binding var selectedModel: TranscriptionModel
    let isDisabled: Bool

    @State private var showingPopover = false
    @State private var isButtonHovered = false
    @State private var hoveredModelInPopover: TranscriptionModel?

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selectedModel.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(
                isButtonHovered || showingPopover
                    ? Color.accentColor
                    : Color.primary
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        isButtonHovered || showingPopover
                            ? Color.accentColor.opacity(0.18)
                            : Color.secondary.opacity(0.12)
                    )
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(isDisabled)
        .onHover { isHovering in
            isButtonHovered = isHovering
            if isHovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
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

private struct APIKeySheetView: View {
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

private struct HowToTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [HowToTarget: Anchor<CGRect>] = [:]

    static func reduce(value: inout [HowToTarget: Anchor<CGRect>], nextValue: () -> [HowToTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
    }
}

private extension View {
    func howToTarget(_ target: HowToTarget) -> some View {
        anchorPreference(key: HowToTargetPreferenceKey.self, value: .bounds) { [target: $0] }
    }
}

private struct SpotlightShape: Shape {
    let holeRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(in: holeRect, cornerSize: CGSize(width: 14, height: 14))
        return path
    }
}

private struct HowToGuideOverlay: View {
    let step: HowToStep
    let stepNumber: Int
    let totalSteps: Int
    let highlightRect: CGRect
    let onBack: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = instructionLayout(in: proxy.size)

            ZStack {
                SpotlightShape(holeRect: highlightRect)
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))

                // Allow users to advance the tutorial by clicking anywhere.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onNext()
                    }

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.95), lineWidth: 2)
                    .frame(width: max(0, highlightRect.width), height: max(0, highlightRect.height))
                    .position(x: highlightRect.midX, y: highlightRect.midY)
                    .shadow(color: .black.opacity(0.3), radius: 16)

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

    private func instructionLayout(in size: CGSize) -> (cardWidth: CGFloat, center: CGPoint) {
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

        if rightSpace >= cardWidth + gap {
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
