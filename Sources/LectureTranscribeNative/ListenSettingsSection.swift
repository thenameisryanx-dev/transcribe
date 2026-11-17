import SwiftUI

/// Settings ▸ Listen: the downloaded voice models and the speech saved from reading, with ways to free the space.
struct ListenSettingsSection: View {
    @ObservedObject var model: ListenModel
    @State private var modelsSize: Int64 = 0
    @State private var savedSpeechSize: Int64 = 0
    @State private var confirmingDelete = false

    var body: some View {
        Section {
            Picker("Sentences at Once", selection: $model.sentencesAtOnce) {
                ForEach(ListenVoiceModel.sentencesAtOnceChoices, id: \.self) { count in
                    Text(count == ListenVoiceModel.defaultSentencesAtOnce() ? "\(count) (recommended for this Mac)" : "\(count)")
                        .tag(count)
                }
            }
            .help("How many sentences the voice makes at the same time. More is faster, but keeps the GPU busier while it works.")
            LabeledContent("Voice Models") {
                HStack(spacing: 10) {
                    switch model.voiceDownload {
                    case .downloading(let progress):
                        ProgressView(value: progress.fraction)
                            .frame(minWidth: 60, maxWidth: 120)
                        Text("\(Self.format(progress.bytesDone)) of \(Self.format(progress.totalBytes))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                            .help(VoiceSetupBar.progressLine(progress))
                        Button("Cancel", action: model.cancelVoiceDownload)
                    case .failed:
                        Text("Didn't finish downloading")
                            .foregroundStyle(.secondary)
                        Button("Try Again", action: model.downloadVoice)
                    case .downloaded:
                        Text("Downloaded (\(Self.format(modelsSize)))")
                            .foregroundStyle(.secondary)
                        Button("Delete…") { confirmingDelete = true }
                    case .notDownloaded:
                        Text("Not downloaded")
                            .foregroundStyle(.secondary)
                        Button("Download", action: model.downloadVoice)
                            .help("Download the voice (about \(Self.format(ListenVoiceModel.approximateDownloadSize)), once)")
                    }
                }
            }
            if case .failed(let failure) = model.voiceDownload {
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent("Saved Speech") {
                HStack(spacing: 10) {
                    Text(Self.format(savedSpeechSize))
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        model.clearSavedSpeech()
                        savedSpeechSize = 0
                    }
                    .disabled(savedSpeechSize == 0)
                }
            }
        } header: {
            Text("Listen")
        } footer: {
            Text("Listen reads text aloud on this Mac with Qwen3-TTS and times each word with Qwen3-ForcedAligner. "
                + "The voice downloads once (about 3.5 GB), from the Listen pane or here, and then works offline; "
                + "your text never leaves this Mac. Play makes the speech for the whole text first, several sentences at once, then opens the reader. "
                + "Making more at once is faster until the GPU is full (on a base M4, 24 at once is about 3.6 times as fast "
                + "as 1, and 32 is no faster) but keeps "
                + "the GPU busier, so other apps may feel slower while it works. Speech already made is saved so it plays at once next time; "
                + "speech not heard for a month is removed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task(id: model.modelsDownloaded) { await refreshSizes() }
        .onAppear(perform: model.refreshVoiceDownload)
        .confirmationDialog("Delete the voice models?", isPresented: $confirmingDelete) {
            Button("Delete Voice Models", role: .destructive) {
                model.deleteVoiceModels()
                Task { await refreshSizes() }
            }
        } message: {
            Text("This deletes the voice models and frees \(Self.format(modelsSize)). To listen again, download the voice again from the Listen pane or here.")
        }
    }

    private func refreshSizes() async {
        modelsSize = await model.voiceModelsSize()
        savedSpeechSize = await model.savedSpeechSize()
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
