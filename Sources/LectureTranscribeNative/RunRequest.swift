import Foundation

/// What one transcription run does, worked out from the Transcribe pane's options.
/// Options that don't apply to the run are dropped here, so the run and its history entry show what really ran.
struct RunRequest: Equatable, Sendable {
    /// The Transcribe pane's options when Start is pressed.
    struct Options: Equatable, Sendable {
        var model: TranscriptionModel
        var diarize: Bool
        var subtitles: Bool
        var embedSubtitles: Bool
        var audioTrack: Int
        /// Already resolved for the model (see `TranscribeViewModel.spokenLanguageCodesForRun`).
        var languages: [String]
        var contextPrompt: String
        var consistencyMode: Bool
        var chunkLength: ChunkLength
        var keywordsText: String
    }

    var inputPath: String
    var outputDirectory: String
    var model: TranscriptionModel
    var diarize: Bool
    var subtitles: Bool
    var embedSubtitles: Bool
    var audioTrack: Int
    var languages: [String]
    var context: String
    var carryContext: Bool
    var chunkSeconds: Int?
    var keywords: [String]

    init(inputPath: String, outputDirectory: String, options: Options) {
        self.inputPath = inputPath
        self.outputDirectory = outputDirectory
        model = options.model
        subtitles = options.subtitles
        // The subtitled copy is made from the subtitles, so it's only made with them.
        embedSubtitles = options.subtitles && options.embedSubtitles
        // Subtitles don't carry speaker labels, and not every model can label speakers.
        diarize = options.diarize && options.model.supportsDiarization && !options.subtitles
        audioTrack = options.audioTrack
        languages = options.languages
        // Speaker labels and subtitles both run on the diarize model, which takes no prompt or chunk length.
        let usesDiarizeModel = diarize || subtitles
        context = usesDiarizeModel ? "" : options.contextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        carryContext = !usesDiarizeModel && options.consistencyMode && options.model.supportsConsistencyMode
        chunkSeconds = usesDiarizeModel ? nil : options.chunkLength.seconds
        keywords = !usesDiarizeModel && options.model.supportsKeywords ? KeywordList.parse(options.keywordsText) : []
    }

    /// The run history entry for this run as it starts.
    func historyEntry(id: UUID = UUID(), startedAt: Date = Date()) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            id: id,
            startedAt: startedAt,
            finishedAt: nil,
            inputPath: inputPath,
            outputPath: nil,
            outputDirectory: outputDirectory,
            diarize: diarize,
            status: .running,
            errorMessage: nil,
            model: model.rawValue,
            context: context.isEmpty ? nil : context,
            keywords: keywords.isEmpty ? nil : keywords,
            consistencyMode: carryContext,
            chunkSeconds: chunkSeconds,
            subtitles: subtitles ? true : nil,
            audioTrack: audioTrack > 0 ? audioTrack : nil,
            embedSubtitles: embedSubtitles ? true : nil
        )
    }
}
