import SwiftUI

/// Settings ▸ Listen: the downloaded voice models and the speech saved from reading, with ways to free the space.
struct ListenSettingsSection: View {
    @ObservedObject var model: ListenModel
    @State private var modelsSize: Int64 = 0
    @State private var savedSpeechSize: Int64 = 0
    @State private var confirmingDelete = false

    var body: some View {
        Section {
            Picker("Voice Model", selection: $model.engine) {
                ForEach(ListenEngine.allCases) { engine in
                    Text("\(engine.displayName) — \(engine.summary)").tag(engine)
                }
            }
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
            Text("Listen reads text aloud on this Mac with Kokoro (fast, on the Neural Engine) or Qwen3-TTS (more "
                + "expressive, but slower than the speech plays on most Macs), and times each word with "
                + "Qwen3-ForcedAligner. Each voice model downloads once (Kokoro about 1.3 GB with the aligner, Qwen3-TTS "
                + "about 3.5 GB) and then works offline. Sentences already read are saved so they play at once next "
                + "time; ones not heard for a month are removed.")
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
            Text("This deletes both voice models and frees \(Self.format(modelsSize)). Listen downloads the one it needs again the next time you press Play.")
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
