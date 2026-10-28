import Foundation

/// A transcription run done in Swift: a plain transcript, one with speaker labels, or subtitles. Ported from the
/// backend's `run_transcription_job`: the recording is cut into chunks at pauses, each chunk is sent to OpenAI
/// (and a plain transcript's text checked), finished chunks are saved so a failed run can resume, and the output
/// is written only once every chunk succeeds. Tests check its output against the backend's (Tests/golden/runs).
struct TranscriptJob: Sendable {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// gpt-transcribe drops speech without a language, so it gets English when none is chosen.
    static let defaultLanguages = ["en"]
    /// Extra attempts, with the same model, when a chunk's text fails a check.
    static let checkRetries = 2
    /// gpt-4o-transcribe and gpt-4o-mini-transcribe stop writing after this many output tokens and return what
    /// they have; a chunk that reaches it is split at a pause and each piece is transcribed on its own.
    static let outputTokenLimit = 2048
    static let outputLimitedModels: Set<String> = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    /// A capped chunk is halved at most twice; pieces shorter than this that still hit the cap are looping.
    static let maxOutputSplitDepth = 2
    static let minOutputSplitSeconds = 60.0
    /// Overall progress (percent) given to preparing the audio; transcribing the chunks fills the rest.
    static let prepareProgress = 15.0
    static let defaultChunkSeconds = 300
    static let defaultMaxParallel = 4

    /// Speaker labels and subtitles both use the diarize model: it labels speakers, and it's the only model
    /// that returns a start and end time for what it hears.
    static let diarizeModel = "gpt-4o-transcribe-diarize"
    /// The diarize model refuses longer audio.
    static let diarizeMaxSeconds = 1400
    /// Speaker labels for audio up to this long are made in one request (kept under the limit to be safe).
    static let defaultDiarizeSingleRequestSeconds = 1300.0
    /// Smaller chunks reduce timeout risk on long recordings.
    static let defaultDiarizeChunkSeconds = 600

    let request: RunRequest
    let apiKey: String
    let openAI: OpenAIClient
    let media: MediaTools
    /// Scratch space: chunks go in `chunks/`, saved results in `chunk_results/`.
    let workDirectory: URL
    let maxParallel: Int
    let emit: @Sendable (BackendStreamEvent) -> Void
    var now: @Sendable () -> Date = { Date() }
    var diarizeSingleRequestSeconds = TranscriptJob.defaultDiarizeSingleRequestSeconds
    var diarizeChunkSeconds = TranscriptJob.defaultDiarizeChunkSeconds

    static func maxParallel(environment: [String: String]) -> Int {
        max(1, Int(environment["TRANSCRIBE_MAX_PARALLEL"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? defaultMaxParallel)
    }

    private func log(_ message: String) { emit(.log(message)) }

    /// What every kind of run works from.
    private struct Setup {
        let input: URL
        /// The audio actually transcribed: the input, or an .m4a copy of a .qta file's chosen track.
        var workingInput: URL
        /// The track of `workingInput` to transcribe.
        var audioTrack: Int
        let languages: [String]?
        let runID: String
        /// The input's name made safe for file names.
        let stem: String
        let outputDirectory: URL
        let results: ChunkResultStore
    }

    /// The transcript or subtitle file it wrote.
    func run() async throws -> URL {
        let resultsRoot = workDirectory.appendingPathComponent("chunk_results")
        ChunkResultStore.prune(resultsRoot)
        let input = URL(fileURLWithPath: request.inputPath)
        let model = request.model.rawValue

        // Videos can carry one audio track per language; only the chosen one (0 = the first) is transcribed.
        let audioTrack = request.audioTrack
        let tracks = try await offload { media.audioTracks(input) }
        if !tracks.isEmpty && !tracks.indices.contains(audioTrack) {
            throw Failure("Audio track \(audioTrack + 1) doesn't exist; this file has \(tracks.count) audio track(s).")
        }
        if tracks.count > 1 {
            let track = tracks[audioTrack]
            let details = [track.language, track.title].filter { !$0.isEmpty }.joined(separator: ", ")
            log("Audio track: \(audioTrack + 1) of \(tracks.count) (\(details.isEmpty ? "no language tag" : details)).")
        }

        // RunRequest has already turned off what doesn't apply: speaker labels with subtitles, and the prompt,
        // keywords and chunk length with either (the diarize model takes none of them).
        let usesDiarizeModel = request.diarize || request.subtitles
        if request.subtitles {
            log("Making subtitles with \(Self.diarizeModel), the model that returns timing for each line.")
        } else {
            log("Using transcription model: \(model)")
        }
        // gpt-transcribe takes the whole list; the GPT-4o and diarize models take at most one `language`.
        let languages: [String]?
        if request.model == .gptTranscribe && !usesDiarizeModel {
            languages = request.languages.isEmpty ? Self.defaultLanguages : request.languages
            log("Spoken languages: \(languages!.joined(separator: ", "))")
        } else {
            languages = request.languages.isEmpty ? nil : request.languages
            log("Spoken language: \(TranscriptionRequest.singleLanguage(languages) ?? "auto-detect")")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let outputDirectory = URL(fileURLWithPath: request.outputDirectory)
        let setup = Setup(
            input: input,
            workingInput: input,
            audioTrack: audioTrack,
            languages: languages,
            runID: formatter.string(from: now()),
            stem: TranscriptText.safeStem(input),
            outputDirectory: outputDirectory,
            results: ChunkResultStore(root: resultsRoot)
        )

        // Transcripts are written only after every chunk succeeds, so a failed or cancelled run never leaves
        // a partial file in the output folder.
        if request.subtitles {
            return try await writeSubtitles(setup)
        }
        if request.diarize {
            return try await writeSpeakerLabels(setup)
        }
        return try await writeTranscript(setup)
    }

    /// Where a .qta file's audio is copied to for the run; nil for other files.
    private func convertedInput(_ setup: Setup) -> URL? {
        guard setup.input.pathExtension.lowercased() == "qta" else { return nil }
        return workDirectory.appendingPathComponent("converted_inputs/\(setup.stem)_\(setup.runID).m4a")
    }

    /// The audio to transcribe: a .qta file's chosen track copied out to an .m4a (holding only that track), or
    /// the input itself. `body` gets it; the copy is removed afterwards.
    private func withWorkingInput(_ setup: Setup, _ body: (Setup) async throws -> URL) async throws -> URL {
        guard let converted = convertedInput(setup) else {
            try await logChannels(setup)
            return try await body(setup)
        }
        defer { try? FileManager.default.removeItem(at: converted) }
        log("Detected .qta input. Converting to .m4a...")
        emit(.status("Converting .qta input..."))
        try await offload { try media.convertQTA(setup.input, to: converted, audioTrack: setup.audioTrack) }
        var working = setup
        working.workingInput = converted
        working.audioTrack = 0
        log("Converted .qta to: \(converted.lastPathComponent)")
        try await logChannels(working)
        return try await body(working)
    }

    /// Surround sources keep dialogue in the center channel; splitting mixes them down to mono.
    private func logChannels(_ setup: Setup) async throws {
        if let channels = try await offload({ media.channelCount(setup.workingInput, audioTrack: setup.audioTrack) }), channels > MediaTools.maxCopyChannels {
            log("Source audio has \(channels) channels. Mixing down to mono for transcription.")
        }
    }

    // MARK: - Plain transcripts

    private func writeTranscript(_ setup: Setup) async throws -> URL {
        let model = request.model.rawValue
        // Accents kept with their letters (NFC), as the backend does, so either can reuse the other's saved chunks.
        let trimmedContext = request.context.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let context: String? = trimmedContext.isEmpty ? nil : trimmedContext
        let carryContext = request.carryContext && request.model.supportsConsistencyMode
        let keywords = request.model.supportsKeywords ? request.keywords.map(\.precomposedStringWithCanonicalMapping) : []
        log("Context prompt: \(context.map { "\($0.count) characters" } ?? "none")")
        log("Keywords: \(keywords.isEmpty ? "none" : keywords.joined(separator: ", "))")
        log("Consistency mode (carry context between chunks): \(carryContext ? "on" : "off")")

        try FileManager.default.createDirectory(at: setup.outputDirectory, withIntermediateDirectories: true)
        let output = setup.outputDirectory.appendingPathComponent("\(setup.stem)_\(setup.runID).txt")
        return try await withWorkingInput(setup) { setup in
            try await writeTranscript(setup, to: output, model: model, context: context, carryContext: carryContext, keywords: keywords)
        }
    }

    private func writeTranscript(
        _ setup: Setup,
        to output: URL,
        model: String,
        context: String?,
        carryContext: Bool,
        keywords: [String]
    ) async throws -> URL {
        let chunkSeconds = request.chunkSeconds ?? Self.defaultChunkSeconds
        log("Chunk size: \(chunkSeconds / 60) minute(s) per request (cut at the nearest pause).")
        let chunksDirectory = workDirectory.appendingPathComponent("chunks/\(setup.stem)_\(setup.runID)")
        let results = setup.results
        emit(.status("Preparing audio chunks..."))

        let chunkResults: [(text: String, warning: String?)]
        let spans: [(start: Double, end: Double)]
        let parts: [URL]
        do {
            defer { media.removeChunks(in: chunksDirectory) }
            parts = try await split(setup, into: chunksDirectory, chunkSeconds: chunkSeconds)
            log("Prepared \(parts.count) chunk(s) for transcription.")
            results.total = parts.count
            // Chunks are cut at pauses, so their lengths vary; measure them for the section headers.
            spans = try await offload { chunkSpans(parts, fallbackSeconds: Double(chunkSeconds)) }

            let transcriber = ChunkTranscriber(
                job: self, results: results, model: model, languages: setup.languages, context: context, keywords: keywords
            )
            chunkResults = try await reportingSavedChunks(results) {
                if carryContext && parts.count > 1 {
                    return try await transcribeInOrder(parts, transcriber: transcriber)
                }
                return try await inParallel(parts, label: "Transcribing") { try await transcriber.transcribe($0, previousTail: nil) }
            }
        }

        let warnings = chunkResults.compactMap(\.warning)
        warnings.forEach { emit(.warning($0)) }
        var sections = [TranscriptText.header(
            inputPath: setup.input.path,
            workingInputPath: setup.workingInput.path,
            model: model,
            localChunkSeconds: chunkSeconds,
            languages: setup.languages ?? [],
            context: context ?? "",
            keywords: keywords,
            consistencyMode: carryContext,
            chunkWarnings: warnings
        )]
        for (part, (result, span)) in zip(parts, zip(chunkResults, spans)) {
            sections.append("\n\n===== \(part.lastPathComponent) (\(TranscriptText.hhmmss(span.start))-\(TranscriptText.hhmmss(span.end))) =====\n\n")
            if let warning = result.warning {
                sections.append("[WARNING: \(warning)]\n\n")
            }
            let lines = TranscriptText.sentenceLines(result.text)
            sections.append(lines.isEmpty ? result.text : lines.joined(separator: "\n"))
        }
        try Data(sections.joined().utf8).write(to: output)
        results.discard()
        return output
    }

    /// One chunk at a time, each one's prompt ending with the previous chunk's closing words.
    private func transcribeInOrder(_ parts: [URL], transcriber: ChunkTranscriber) async throws -> [(text: String, warning: String?)] {
        let total = parts.count
        log("Transcribing \(total) chunk(s) one at a time, carrying context between chunks.")
        emit(.status("Transcribing: 0/\(total) chunks done"))
        var results: [(text: String, warning: String?)] = []
        for (index, part) in parts.enumerated() {
            var tail: String?
            if let previous = results.last {
                if previous.warning != nil || previous.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    log("Not carrying context into \(part.lastPathComponent): the previous chunk failed its check.")
                } else {
                    tail = TranscriptText.transcriptTail(previous.text)
                }
            }
            results.append(try await transcriber.transcribe(part, previousTail: tail))
            log("Finished chunk \(index + 1)/\(total): \(part.lastPathComponent)")
            emit(.status("Transcribing: \(index + 1)/\(total) chunks done"))
            emit(.progress(progress(done: index + 1, total: total)))
        }
        return results
    }

    // MARK: - Speaker labels

    private func writeSpeakerLabels(_ setup: Setup) async throws -> URL {
        try FileManager.default.createDirectory(at: setup.outputDirectory, withIntermediateDirectories: true)
        let output = setup.outputDirectory.appendingPathComponent("\(setup.stem)_\(setup.runID)_diarize.txt")
        return try await withWorkingInput(setup) { try await writeSpeakerLabels($0, to: output) }
    }

    private func writeSpeakerLabels(_ setup: Setup, to output: URL) async throws -> URL {
        let input = setup.input
        let working = setup.workingInput
        let duration = try await offload { media.duration(working) }

        if 0 < duration && duration <= diarizeSingleRequestSeconds {
            emit(.status("Preparing audio..."))
            let singleDirectory = workDirectory.appendingPathComponent("chunks/\(setup.stem)_\(setup.runID)_single")
            let content: String
            do {
                defer { media.removeChunks(in: singleDirectory) }
                // The original file can be too big (WAV, video) or in a format the API rejects, so it goes through
                // the same copy-or-convert step as chunks. The audio is shorter than the diarize model's limit, so
                // this yields exactly one piece.
                let parts = try await split(setup, into: singleDirectory, chunkSeconds: Self.diarizeMaxSeconds)
                guard parts.count == 1 else {
                    throw Failure("Expected one audio piece for a single diarize request, got \(parts.count).")
                }
                emit(.status("Diarizing (single request)..."))
                let result = try await send(diarizeRequest(setup.languages), audio: parts[0])
                content = result.segments.isEmpty ? result.text : SubtitleText.diarizedLines(result.segments).joined(separator: "\n")
            }
            let header = TranscriptText.header(
                inputPath: input.path,
                workingInputPath: working.path,
                model: Self.diarizeModel,
                responseFormat: "diarized_json",
                chunkingStrategy: "auto",
                durationSeconds: duration
            )
            try Data((header + content).utf8).write(to: output)
            emit(.progress(100))
            return output
        }

        log("Long audio detected. Using local chunks for diarization...")
        emit(.status("Preparing audio chunks..."))
        let chunks = try await diarizeInChunks(
            setup,
            into: workDirectory.appendingPathComponent("chunks/\(setup.stem)_\(setup.runID)_diarize"),
            preparedFor: "diarization",
            label: "Diarizing"
        )
        var lines: [String] = []
        for chunk in chunks {
            if chunk.result.segments.isEmpty {
                lines.append("\n===== \(chunk.part.lastPathComponent) =====\n")
                lines += TranscriptText.sentenceLines(chunk.result.text)
            } else {
                lines += SubtitleText.diarizedLines(chunk.result.segments)
            }
        }
        let header = TranscriptText.header(
            inputPath: input.path,
            workingInputPath: working.path,
            model: Self.diarizeModel,
            responseFormat: "diarized_json",
            chunkingStrategy: "auto",
            localChunkSeconds: diarizeChunkSeconds,
            durationSeconds: duration
        )
        try Data((header + lines.joined(separator: "\n")).utf8).write(to: output)
        setup.results.discard()
        return output
    }

    // MARK: - Subtitles

    /// Transcribes the audio with the diarize model, whose segments are timed, and writes them as an .srt file,
    /// then saves a copy of the video with the subtitles built in when asked.
    private func writeSubtitles(_ setup: Setup) async throws -> URL {
        try FileManager.default.createDirectory(at: setup.outputDirectory, withIntermediateDirectories: true)
        // Video players load subtitles named after the video when they sit next to it, so use its exact name when
        // that file doesn't exist yet. Players that match loosely also find the run-stamped name.
        let name = setup.input.deletingPathExtension().lastPathComponent
        var output = setup.outputDirectory.appendingPathComponent("\(name).srt")
        if FileManager.default.fileExists(atPath: output.path) {
            output = setup.outputDirectory.appendingPathComponent("\(name).\(setup.runID).srt")
        }
        return try await withWorkingInput(setup) { try await writeSubtitles($0, to: output) }
    }

    private func writeSubtitles(_ setup: Setup, to output: URL) async throws -> URL {
        emit(.status("Preparing audio chunks..."))
        let chunks = try await diarizeInChunks(
            setup,
            into: workDirectory.appendingPathComponent("chunks/\(setup.stem)_\(setup.runID)_subtitles"),
            preparedFor: "subtitles",
            label: "Transcribing"
        )
        var cues: [SubtitleText.Cue] = []
        for (index, chunk) in chunks.enumerated() {
            let chunkCues = SubtitleText.cues(chunk.result.segments, offsetSeconds: chunk.offset, chunk: index)
            if chunkCues.isEmpty && !chunk.result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emit(.warning("\(chunk.part.lastPathComponent): the model returned text without timing, so this part has no subtitles."))
            }
            cues += chunkCues
        }
        guard !cues.isEmpty else {
            throw Failure("No speech was found in this file, so there are no subtitles to write.")
        }
        try Data(SubtitleText.srt(cues).utf8).write(to: output)
        log("Wrote \(cues.count) subtitle lines.")
        setup.results.discard()

        if request.embedSubtitles {
            try await saveSubtitledCopy(setup, srt: output)
        }
        return output
    }

    /// Saves a copy of the original video with the .srt built in as a subtitle track, for players like QuickTime
    /// which can't load an .srt file. The .srt is already written, so a failed copy is a warning, not a failed run.
    private func saveSubtitledCopy(_ setup: Setup, srt: URL) async throws {
        let input = setup.input
        let suffix = input.pathExtension.isEmpty ? "" : ".\(input.pathExtension)"
        guard MediaTools.embedSubtitleCodecs[input.pathExtension.lowercased()] != nil else {
            let kinds = MediaTools.embedSubtitleCodecs.keys.sorted().map { ".\($0)" }.joined(separator: ", ")
            log("Subtitles can only be built into \(kinds) videos, so no copy of this \(suffix.isEmpty ? "file" : suffix.lowercased()) was saved.")
            return
        }

        // Named after the video like the .srt; a run-stamped name keeps an earlier copy from being overwritten.
        let name = input.deletingPathExtension().lastPathComponent
        let plainName = setup.outputDirectory.appendingPathComponent("\(name).subtitled\(suffix)")
        let output = FileManager.default.fileExists(atPath: plainName.path)
            ? setup.outputDirectory.appendingPathComponent("\(name).subtitled.\(setup.runID)\(suffix)")
            : plainName
        if FileManager.default.fileExists(atPath: output.path) {
            emit(.warning("\(output.lastPathComponent) already exists, so no copy of the video with subtitles was saved."))
            return
        }

        emit(.status("Saving a copy of the video with subtitles..."))
        let emit = self.emit
        let reported = Counter(-1)
        let language = TranscriptionRequest.singleLanguage(setup.languages)
        do {
            try await offload {
                try media.embedSubtitlesCopy(video: input, srt: srt, output: output, language: language, audioTrack: setup.audioTrack) { fraction in
                    // The progress bar is already full from transcribing, so the copy's progress goes in the status.
                    let percent = Int(fraction * 100)
                    if percent >= reported.value + 10 {
                        reported.value = percent
                        emit(.status("Saving a copy of the video with subtitles (\(percent)%)..."))
                    }
                }
            }
        } catch let error as MediaTools.Failure {
            emit(.warning("Couldn't save a copy of the video with subtitles: \(error.localizedDescription) The .srt file was saved."))
            return
        }
        log("Saved a copy of the video with subtitles: \(output.path)")
        emit(.subtitledCopy(output.resolvingSymlinksInPath().path))
    }

    // MARK: - Diarize requests

    private func diarizeRequest(_ languages: [String]?) -> TranscriptionRequest {
        TranscriptionRequest(model: Self.diarizeModel, responseFormat: "diarized_json", chunkingStrategy: "auto", languages: languages ?? [])
    }

    /// Splits the recording into the diarize model's chunks and sends them, reusing saved results. Each chunk
    /// comes back with where it starts in the recording.
    private func diarizeInChunks(
        _ setup: Setup,
        into directory: URL,
        preparedFor purpose: String,
        label: String
    ) async throws -> [(part: URL, offset: Double, result: TranscriptionResult)] {
        let results = setup.results
        defer { media.removeChunks(in: directory) }
        let parts = try await split(setup, into: directory, chunkSeconds: diarizeChunkSeconds)
        log("Prepared \(parts.count) chunk(s) for \(purpose).")
        results.total = parts.count
        // Offsets depend on earlier chunks' real lengths, so measure them before fanning out.
        let fallback = Double(diarizeChunkSeconds)
        let spans = try await offload { chunkSpans(parts, fallbackSeconds: fallback) }
        let languages = setup.languages
        let responses = try await reportingSavedChunks(results) {
            try await inParallel(parts, label: label) { try await diarizeSaved($0, languages: languages, results: results) }
        }
        return zip(parts, zip(spans, responses)).map { ($0, $1.0.start, $1.1) }
    }

    /// One chunk's diarize response, or its saved result from an earlier attempt.
    private func diarizeSaved(_ chunk: URL, languages: [String]?, results: ChunkResultStore) async throws -> TranscriptionResult {
        let key = try results.key(chunk: chunk, request: ["kind": "diarize", "model": Self.diarizeModel, "languages": languages])
        if let saved = results.load(key), saved["segments"] is [Any], saved["text"] is String {
            results.markReused(key)
            log("Using the saved result of \(chunk.lastPathComponent) from an earlier attempt.")
            return TranscriptionResult(object: saved)
        }
        let result = try await send(diarizeRequest(languages), audio: chunk)
        // Only the parts the transcript and subtitles use, in the form the backend saves them.
        results.save(key, [
            "text": result.text,
            "segments": result.segments.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end, "text": $0.text] as [String: Any?] },
        ])
        return result
    }

    // MARK: - Shared steps

    private func split(_ setup: Setup, into directory: URL, chunkSeconds: Int) async throws -> [URL] {
        let emit = self.emit
        return try await offload {
            try media.split(setup.workingInput, into: directory, chunkSeconds: chunkSeconds, audioTrack: setup.audioTrack) {
                emit(.progress(Self.prepareProgress * $0))
            }
        }
    }

    /// (start, end) of each chunk within the recording, from the chunks' measured lengths.
    private func chunkSpans(_ parts: [URL], fallbackSeconds: Double) -> [(start: Double, end: Double)] {
        var start = 0.0
        return parts.map { part in
            let duration = media.duration(part)
            let end = start + (duration > 0 ? duration : fallbackSeconds)
            defer { start = end }
            return (start, end)
        }
    }

    private func progress(done: Int, total: Int) -> Double {
        Self.prepareProgress + (100 - Self.prepareProgress) * Double(done) / Double(total)
    }

    /// Logs how many chunks were reused, or on a failure or cancel, how many are saved for the next attempt.
    private func reportingSavedChunks<T>(_ results: ChunkResultStore, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            if results.reusedCount > 0 {
                log("Reused \(results.reusedCount) of \(results.total) chunk(s) saved from an earlier attempt.")
            }
            return value
        } catch {
            if results.keptCount > 0 {
                log("\(results.keptCount) of \(results.total) chunk(s) finished and were saved. Run this again with the same settings to send only the rest.")
            }
            throw error
        }
    }

    /// Up to `maxParallel` chunks at a time, results in chunk order. When a chunk fails, chunks already sent
    /// are paid for either way, so they finish (and are saved) before the failure is reported; chunks not sent
    /// yet aren't sent. A cancel stops them all at once.
    private func inParallel<T: Sendable>(
        _ parts: [URL],
        label: String,
        _ work: @escaping @Sendable (URL) async throws -> T
    ) async throws -> [T] {
        let total = parts.count
        let workers = max(1, min(maxParallel, total))
        log("\(label) \(total) chunk(s), up to \(workers) at a time.")
        emit(.status("\(label): 0/\(total) chunks done"))
        var results = [T?](repeating: nil, count: total)
        try await withThrowingTaskGroup(of: (Int, Result<T, Error>).self) { group in
            var next = 0
            var running = 0
            var failure: Error?
            var done = 0
            func startNext() {
                guard failure == nil, next < total else { return }
                let index = next
                next += 1
                running += 1
                group.addTask {
                    do {
                        return (index, .success(try await work(parts[index])))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<workers { startNext() }
            while let (index, result) = try await group.next() {
                running -= 1
                switch result {
                case let .success(value):
                    results[index] = value
                    done += 1
                    log("Finished chunk \(index + 1)/\(total): \(parts[index].lastPathComponent)")
                    emit(.status("\(label): \(done)/\(total) chunks done"))
                    emit(.progress(progress(done: done, total: total)))
                    startNext()
                case let .failure(error):
                    if error is CancellationError || Task.isCancelled {
                        group.cancelAll()
                        throw CancellationError()
                    }
                    if failure == nil {
                        failure = error
                        if running > 0 {
                            log("A chunk failed. Waiting for the \(running) chunk(s) already sent so they can be saved...")
                            emit(.status("Stopping after a failed chunk..."))
                        }
                    }
                }
            }
            if let failure { throw failure }
        }
        return results.map { $0! }
    }

    /// One request to OpenAI, re-encoding the chunk once if OpenAI can't read it (`create_transcription_with_retry`).
    func send(_ request: TranscriptionRequest, audio chunk: URL) async throws -> TranscriptionResult {
        let onRetry: @Sendable (String) -> Void = { [emit] in emit(.log($0)) }
        do {
            return try await openAI.transcribe(request, audio: chunk, apiKey: apiKey, onRetry: onRetry)
        } catch let error as OpenAIError where error.isInvalidAudio {
            log("API rejected \(chunk.lastPathComponent) as unsupported. Re-encoding once and retrying...")
            let repaired = try await offload { try media.repairedForAPI(chunk) }
            defer { try? FileManager.default.removeItem(at: repaired) }
            return try await openAI.transcribe(request, audio: repaired, apiKey: apiKey, onRetry: onRetry)
        } catch let error as OpenAIError {
            let message = error.message.lowercased()
            if let prompt = request.prompt, message.contains("prompt") {
                log("The API rejected the prompt for \(chunk.lastPathComponent) (\(prompt.count) characters). Try a shorter Context in Settings.")
            }
            if !request.keywords.isEmpty, message.contains("keyword") {
                log("The API rejected the keywords for \(chunk.lastPathComponent) (\(request.keywords.count) keywords). Try fewer or shorter keywords.")
            }
            throw error
        }
    }

    /// Runs blocking ffmpeg work off Swift's shared threads; a cancel stops the tool that's running.
    func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try work() })
                }
            }
        } onCancel: {
            media.cancel()
        }
    }

    /// The short message for the error alert and run history (the backend's `describe_run_error`), and whether
    /// the API key caused it, so the app can ask for a new one.
    static func describe(_ error: Error) -> (message: String, isAPIKeyProblem: Bool) {
        if let error = error as? OpenAIError {
            switch error.status {
            case 401:
                return ("OpenAI rejected your API key. Set a valid key in Settings, then try again.", true)
            case 403:
                return ("Your OpenAI API key doesn't have access to this model. Check your OpenAI project settings.", false)
            case 429 where error.code == "insufficient_quota":
                return ("Your OpenAI account is out of credits. Add billing at platform.openai.com, then try again.", false)
            case 429:
                return ("OpenAI is rate limiting requests right now. Wait a minute, then try again.", false)
            default:
                return (error.localizedDescription, false)
            }
        }
        if error is URLError {
            return ("Couldn't reach OpenAI. Check your internet connection, then try again.", false)
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return (message.isEmpty ? String(describing: type(of: error)) : message, false)
    }
}

/// A number one closure updates across calls (ffmpeg's progress lines arrive one at a time).
private final class Counter: @unchecked Sendable {
    var value: Int
    init(_ value: Int) { self.value = value }
}

/// Transcribes one chunk, reusing its saved result when there is one (`transcribe_chunk_checked`).
private struct ChunkTranscriber: Sendable {
    let job: TranscriptJob
    let results: ChunkResultStore
    let model: String
    let languages: [String]?
    let context: String?
    let keywords: [String]

    private func log(_ message: String) { job.emit(.log(message)) }

    func transcribe(_ chunk: URL, previousTail: String?) async throws -> (text: String, warning: String?) {
        let key = try results.key(chunk: chunk, request: [
            "kind": "transcript",
            "model": model,
            "languages": languages,
            "context": context,
            "keywords": keywords,
            "previous_tail": previousTail,
        ])
        if let saved = results.load(key)?["text"] as? String {
            results.markReused(key)
            log("Using the saved result of \(chunk.lastPathComponent) from an earlier attempt.")
            return (saved, nil)
        }
        let result = try await checked(chunk, previousTail: previousTail, splitDepth: 0)
        // A chunk that failed its checks is sent again next time instead of reusing its doubtful text.
        if result.warning == nil {
            results.save(key, ["text": result.text])
        }
        return result
    }

    /// Transcribes one chunk and checks the text: every model's for a repeated passage, gpt-transcribe's also for
    /// empty or implausibly long text. A failed check is retried with the same model; if the last attempt still
    /// fails, its text is kept with a warning. Retries drop the previous chunk's excerpt so it can't cause the
    /// same failure twice. A GPT-4o chunk that reaches the output cap is split and transcribed in pieces.
    private func checked(_ chunk: URL, previousTail: String?, splitDepth: Int) async throws -> (text: String, warning: String?) {
        var tail = previousTail
        var prompt = TranscriptText.chunkPrompt(context: context, previousTail: tail)
        let prompting = context != nil || tail != nil
        if prompting { logPrompt(chunk, prompt) }

        let attempts = 1 + TranscriptJob.checkRetries
        var text = ""
        var warning: String?
        for attempt in 1...attempts {
            if attempt > 1, tail != nil {
                tail = nil
                prompt = TranscriptText.chunkPrompt(context: context, previousTail: nil)
                log("Retrying \(chunk.lastPathComponent) without the previous chunk's excerpt.")
                logPrompt(chunk, prompt)
            }
            let isGPTTranscribe = model == TranscriptionRequest.gptTranscribe
            let request = TranscriptionRequest(
                model: model,
                responseFormat: "json",
                languages: isGPTTranscribe ? (languages ?? TranscriptJob.defaultLanguages) : (languages ?? []),
                prompt: prompt,
                keywords: keywords
            )
            let response = try await job.send(request, audio: chunk)
            let raw = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isGPTTranscribe, TranscriptJob.outputLimitedModels.contains(model), (response.outputTokens ?? 0) >= TranscriptJob.outputTokenLimit {
                return try await inPieces(chunk, cappedText: raw, splitDepth: splitDepth)
            }
            text = removeEcho(raw, tail: tail, chunk: chunk)
            warning = try await checkFailure(text, chunk: chunk)
            guard let failure = warning else { return (text, nil) }
            log("\(failure) (attempt \(attempt)/\(attempts)).")
        }
        return (text, "\(warning!) after \(attempts) attempts.")
    }

    private func logPrompt(_ chunk: URL, _ prompt: String?) {
        if let prompt {
            log("Prompt for \(chunk.lastPathComponent):\n\(prompt)")
        } else {
            log("Prompt for \(chunk.lastPathComponent): (none)")
        }
    }

    private func removeEcho(_ text: String, tail: String?, chunk: URL) -> String {
        guard let tail, !tail.isEmpty else { return text }
        let (stripped, removed) = TranscriptText.stripEchoedTail(text, tail: tail)
        if removed > 0 {
            log("\(chunk.lastPathComponent): removed \(removed) word(s) at the start that repeated the previous chunk's excerpt.")
        }
        return stripped
    }

    /// Why a chunk's transcript looks wrong, or nil if it passes.
    private func checkFailure(_ text: String, chunk: URL) async throws -> String? {
        let name = chunk.lastPathComponent
        if model == TranscriptionRequest.gptTranscribe {
            if text.isEmpty {
                return "\(name): \(model) returned no text"
            }
            let duration = try await job.offload { job.media.duration(chunk) }
            if TranscriptText.looksRepeated(text, durationSeconds: duration) {
                return "\(name): \(model) returned \(TranscriptText.words(text).count) words, more than could be spoken in this chunk (likely repeated text)"
            }
        }
        if let repeated = TranscriptText.findRepeatedPassage(text) {
            return "\(name): \(model) repeated a passage of about \(repeated.length) words, starting \"\(repeated.opening)…\" (check this part of the transcript)"
        }
        return nil
    }

    /// Re-transcribes a chunk whose text hit the GPT-4o output cap, as smaller pieces cut at pauses, named after
    /// the chunk (part_002 -> part_002a, part_002b). If it can't be split further, the capped text is kept with a
    /// warning that its end is missing.
    private func inPieces(_ chunk: URL, cappedText: String, splitDepth: Int) async throws -> (text: String, warning: String?) {
        let name = chunk.lastPathComponent
        let cappedWarning = "\(name): \(model) hit its \(TranscriptJob.outputTokenLimit)-token output limit, so the end of this part is likely missing"
        let duration = try await job.offload { job.media.duration(chunk) }
        if splitDepth >= TranscriptJob.maxOutputSplitDepth || duration < 2 * TranscriptJob.minOutputSplitSeconds {
            log("\(cappedWarning).")
            return (cappedText, cappedWarning)
        }
        log("\(name): \(model) stopped at its \(TranscriptJob.outputTokenLimit)-token output limit (\(TranscriptText.words(cappedText).count) words), so the end was cut off. Splitting it and transcribing the pieces...")
        let stem = chunk.deletingPathExtension().lastPathComponent
        let piecesDirectory = chunk.deletingLastPathComponent().appendingPathComponent("\(stem)_pieces")
        var pieces: [URL] = []
        defer {
            pieces.forEach { try? FileManager.default.removeItem(at: $0) }
            job.media.removeChunks(in: piecesDirectory)
        }
        let parts: [URL]
        do {
            parts = try await job.offload { try job.media.split(chunk, into: piecesDirectory, chunkSeconds: Int((duration / 2).rounded(.up))) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("\(name): couldn't split it (\(error.localizedDescription)). \(cappedWarning).")
            return (cappedText, cappedWarning)
        }
        for (i, part) in parts.enumerated() {
            let piece = part.deletingLastPathComponent().appendingPathComponent("\(stem)\(Character(Unicode.Scalar(UInt8(97 + i)))).m4a")
            try FileManager.default.moveItem(at: part, to: piece)
            pieces.append(piece)
        }
        log("\(name): split into \(pieces.count) pieces.")
        var texts: [String] = []
        var warnings: [String] = []
        for piece in pieces {
            let result = try await checked(piece, previousTail: nil, splitDepth: splitDepth + 1)
            texts.append(result.text)
            if let warning = result.warning { warnings.append(warning) }
        }
        return (texts.filter { !$0.isEmpty }.joined(separator: " "), warnings.isEmpty ? nil : warnings.joined(separator: "; "))
    }
}
