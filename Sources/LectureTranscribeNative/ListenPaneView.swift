import SwiftUI
import UniformTypeIdentifiers

/// Reads text aloud with an on-device voice, highlighting each word as it's spoken. Click any word to jump to it.
struct ListenPaneView: View {
    @ObservedObject var model: ListenModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ReadingTextView(
                    text: $model.text,
                    readingText: model.document?.text,
                    sentenceRange: model.currentSentenceRange,
                    wordRange: model.currentWordRange,
                    onClickLocation: model.jump(toLocation:)
                )
                if model.text.isEmpty && !model.isReading {
                    placeholder
                }
            }
            if let message = model.errorMessage {
                errorBanner(message)
            }
            Divider()
            transportBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
        .navigationTitle("Listen")
        .navigationSubtitle(model.documentName ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.chooseFile()
                } label: {
                    Label("Open…", systemImage: "doc.badge.plus")
                }
                .help("Open a PDF, Word document or text file to listen to")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Voice", selection: $model.voiceID) {
                        ForEach(ListenVoice.all) { voice in
                            Text("\(voice.name) — \(voice.summary), \(voice.nativeLanguage.displayName)").tag(voice.id)
                        }
                    }
                    .pickerStyle(.inline)
                    Picker("Language", selection: $model.language) {
                        ForEach(ListenLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                } label: {
                    Label(model.voice.name, systemImage: "person.wave.2")
                }
                .help("Voice and language. Every voice reads every language; each sounds most natural in its own.")
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The words let clicks through to the text underneath, so a click anywhere starts typing.
            Group {
                Text("Type or paste text here, or open a file.")
                    .font(.system(size: 18))
                Text("PDFs, Word documents, web pages saved as HTML, and text or Markdown files all work. "
                    + "You can also drop a file here. Press Play to hear it read aloud on this Mac, with each word "
                    + "highlighted as it's spoken; click any word to jump to it.")
                    .font(.callout)
            }
            .allowsHitTesting(false)
            Button("Open File…", action: model.chooseFile)
                .padding(.top, 4)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.horizontal, 33)
        .padding(.vertical, 24)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss") { model.errorMessage = nil }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack(spacing: 14) {
            Button(action: model.previousSentence) {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Previous Sentence")
            .disabled(!model.canGoBack)
            .help("Back to the start of the sentence, or the one before (←)")
            .readerShortcut(.leftArrow, enabled: model.isReading)

            Button(action: model.togglePlayPause) {
                Image(systemName: isPlayingOrWaiting ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
            }
            .buttonStyle(.borderless)
            .disabled(!model.isReading && model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(isPlayingOrWaiting ? "Pause (Space)" : "Read aloud (Space)")
            .readerShortcut(.space, enabled: model.isReading)

            Button(action: model.nextSentence) {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Next Sentence")
            .disabled(!model.canGoForward)
            .help("Next sentence (→)")
            .readerShortcut(.rightArrow, enabled: model.isReading)

            status
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Picker("Speed", selection: $model.speed) {
                    ForEach(ListenModel.speeds, id: \.self) { speed in
                        Text(Self.speedLabel(speed)).tag(speed)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(Self.speedLabel(model.speed))
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Reading speed. The voice keeps its pitch at every speed.")

            if model.isReading {
                Button("Edit Text", action: model.editText)
                    .help("Stop reading and change the text. Your place is kept.")
            } else if !model.text.isEmpty {
                Button("Clear", action: model.clearText)
                    .help("Start again with empty text")
            }
        }
    }

    private var isPlayingOrWaiting: Bool {
        model.playback == .playing || model.playback == .waiting
    }

    @ViewBuilder
    private var status: some View {
        switch model.voiceState {
        case .loading(let progress, let message):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(maxWidth: 160)
                Text(model.modelsDownloaded ? message : "\(message) (about 3.5 GB, once)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            if model.isReading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: model.progress)
                        .frame(maxWidth: 320)
                    Text(readingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if !model.modelsDownloaded {
                Text("The first time, Play downloads the voice (about 3.5 GB). After that it works offline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                // Holds the space, so the controls stay at the leading edge instead of drifting to the middle.
                Color.clear.frame(height: 1)
            }
        }
    }

    private var readingSummary: String {
        guard let document = model.document, let position = model.position else { return "" }
        var parts = ["Sentence \(position.sentence + 1) of \(document.sentences.count)"]
        if let minutes = model.minutesLeft {
            parts.append(minutes < 1 ? "under a minute left" : "about \(Int(minutes.rounded())) min left")
        }
        if model.playback == .waiting {
            parts.append("preparing speech…")
        }
        return parts.joined(separator: " · ")
    }

    static func speedLabel(_ speed: Double) -> String {
        let text = speed.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(speed)) : String(speed)
        return "\(text)×"
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.open(url) }
        }
        return true
    }
}

private extension View {
    /// A keyboard shortcut that only applies while reading, so Space and the arrows still type and move the cursor
    /// while the text is being edited.
    @ViewBuilder
    func readerShortcut(_ key: KeyEquivalent, enabled: Bool) -> some View {
        if enabled {
            keyboardShortcut(key, modifiers: [])
        } else {
            self
        }
    }
}
