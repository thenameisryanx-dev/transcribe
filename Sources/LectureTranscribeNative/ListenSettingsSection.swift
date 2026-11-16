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
                    Text(modelStatus)
                        .foregroundStyle(.secondary)
                    if case .loading = model.voiceState {
                        ProgressView()
                            .controlSize(.small)
                    } else if model.modelsDownloaded {
                        Button("Delete…") { confirmingDelete = true }
                    } else {
                        Button("Download Now", action: model.downloadVoice)
                    }
                }
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
                + "Play makes the speech for the whole text first, several sentences at once, then opens the reader. "
                + "Making more at once is faster (on a base M4, 8 at once is about 3.5 times as fast as 1) but keeps "
                + "the GPU busier, so other apps may feel slower while it works. The voice downloads once (about "
                + "3.5 GB) and then works offline. Speech already made is saved so it plays at once next time; "
                + "speech not heard for a month is removed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task(id: model.modelsDownloaded) { await refreshSizes() }
        .confirmationDialog("Delete the voice models?", isPresented: $confirmingDelete) {
            Button("Delete Voice Models", role: .destructive) {
                model.deleteVoiceModels()
                Task { await refreshSizes() }
            }
        } message: {
            Text("This deletes the voice models and frees \(Self.format(modelsSize)). Listen downloads them again the next time you press Play.")
        }
    }

    private var modelStatus: String {
        switch model.voiceState {
        case .loading(let progress, _):
            return "Downloading… \(Int(progress * 100))%"
        case .failed:
            return "Couldn't download"
        default:
            return model.modelsDownloaded ? "Downloaded (\(Self.format(modelsSize)))" : "Not downloaded"
        }
    }

    private func refreshSizes() async {
        modelsSize = await Task.detached { SpeechModelFiles.size() }.value
        savedSpeechSize = await model.savedSpeechSize()
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
