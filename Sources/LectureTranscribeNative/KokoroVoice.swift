import AudioCommon
import CoreML
import Foundation
import KokoroTTS

/// Kokoro uses Core ML, not MLX, so it has its own queue and can make the next sentence while the aligner times the
/// last one on the GPU.
private let kokoroQueue = DispatchQueue(label: "LectureTranscribe.Listen.Kokoro", qos: .userInitiated)

/// Kokoro-82M: 50 voices in seven languages, 24 kHz audio, on the Neural Engine.
///
/// Its Core ML build makes at most 5 seconds of speech per pass, so a sentence longer than about ten words is made in
/// pieces. speech-swift's own `synthesize` cuts those pieces wherever its token count runs out and joins them with
/// each piece's full lead-in and closing silence (about 0.8 s, mid-sentence). This runs the same model itself
/// instead: it cuts at a comma or other pause where it can and keeps only a natural pause between pieces. It also
/// reads each word's time from the model's own sound durations, so a sentence's words are exactly timed without
/// the aligner.
///
/// Chinese and Japanese text is written without spaces, so it's left to speech-swift's own synthesis and timed by
/// the aligner.
final class KokoroSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    /// Changed when the way speech is made changes, so sentences saved the old way are made again.
    let identifier = "kokoro-pieces|\(SpeechModelFiles.kokoroModelID)"

    /// Only used on `kokoroQueue`, one sentence at a time.
    private struct Loaded: @unchecked Sendable {
        let model: MLModel
        let phonemizer: KokoroPhonemizer
        let voices: [String: [Float]]
    }

    private let lock = NSLock()
    private var loaded: Loaded?
    /// speech-swift's own model, for Chinese and Japanese; made the first time one of them is read.
    private var unspaced: Unspaced?

    private struct Unspaced: @unchecked Sendable {
        let model: KokoroTTSModel
    }

    var isLoaded: Bool { lock.withLock { loaded != nil } }

    /// The files speech-swift downloads for the model, so either can load from the same folder.
    static let modelFiles = [
        "kokoro_5s.mlmodelc/**", "G2PEncoder.mlmodelc/**", "G2PDecoder.mlmodelc/**", "vocab_index.json",
        "g2p_vocab.json", "us_gold.json", "us_silver.json", "dict_de.json", "voices/*.json",
    ]

    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard !isLoaded else { return }
        let directory = try SpeechModelFiles.directory(for: SpeechModelFiles.kokoroModelID)
        progress(0, "Downloading the voice…")
        try await HuggingFaceDownloader.downloadWeights(
            modelId: SpeechModelFiles.kokoroModelID,
            to: directory,
            additionalFiles: Self.modelFiles
        ) { fraction in progress(fraction * 0.7, "Downloading the voice…") }
        // The first load compiles the model for this Mac's Neural Engine (about 20 seconds); later loads take a second.
        progress(0.75, "Loading the voice…")
        let ready: Loaded = try await withCheckedThrowingContinuation { continuation in
            kokoroQueue.async {
                continuation.resume(with: Result {
                    let phonemizer = try KokoroPhonemizer.loadVocab(from: directory.appendingPathComponent("vocab_index.json"))
                    try phonemizer.loadDictionaries(from: directory)
                    let encoder = directory.appendingPathComponent("G2PEncoder.mlmodelc", isDirectory: true)
                    let decoder = directory.appendingPathComponent("G2PDecoder.mlmodelc", isDirectory: true)
                    if FileManager.default.fileExists(atPath: encoder.path), FileManager.default.fileExists(atPath: decoder.path) {
                        try phonemizer.loadG2PModels(encoderURL: encoder, decoderURL: decoder, vocabURL: directory.appendingPathComponent("g2p_vocab.json"))
                    }
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = CoreMLComputeUnitsResolver.resolved(default: .all)
                    let model = try MLModel(contentsOf: directory.appendingPathComponent("kokoro_5s.mlmodelc", isDirectory: true), configuration: configuration)
                    let loaded = Loaded(model: model, phonemizer: phonemizer, voices: try Self.loadVoices(in: directory))
                    // A model's first prediction is several times slower than the ones after it.
                    if let voice = loaded.voices[ListenEngine.kokoro.defaultVoiceID] ?? loaded.voices.values.first {
                        _ = try? Self.run(tokens: [Self.padID] + phonemizer.tokenize("Hello.", maxLength: .max, language: "english").dropFirst().dropLast() + [Self.padID], model: model, voice: voice)
                    }
                    return loaded
                })
            }
        }
        lock.withLock { loaded = ready }
        progress(1, "Voice loaded")
    }

    func synthesize(_ text: String, voice: String, language: ListenLanguage) async throws -> SynthesizedSpeech {
        try Task.checkCancellation()
        if language == .chinese || language == .japanese {
            return try await synthesizeUnspaced(text, voice: voice, language: language)
        }
        guard let loaded = lock.withLock({ loaded }) else { throw SpeechEngineError.notLoaded }
        guard let style = loaded.voices[voice] else { throw SpeechEngineError.noVoice(voice) }
        let speech: SynthesizedSpeech = try await withCheckedThrowingContinuation { continuation in
            kokoroQueue.async {
                continuation.resume(with: Result {
                    let units = text.split(whereSeparator: \.isWhitespace).map(String.init)
                    let tokens = Self.unitTokens(units, text: text) { loaded.phonemizer.tokenize($0, maxLength: .max, language: language.rawValue) }
                    let pieces = try KokoroPieces.plan(units: units, tokens: tokens).flatMap { range in
                        try Self.render(range, units: units, tokens: tokens, model: loaded.model, voice: style, depth: 0)
                    }
                    let joined = KokoroPieces.join(pieces, units: units)
                    let (samples, words) = SpeechPauses.shortening(joined.samples, sampleRate: KokoroTTSModel.outputSampleRate, words: joined.words, longest: KokoroPieces.longestPause)
                    return SynthesizedSpeech(samples: samples, sampleRate: KokoroTTSModel.outputSampleRate, wordTimes: words)
                })
            }
        }
        guard !speech.samples.isEmpty else { throw SpeechEngineError.noAudio }
        return speech
    }

    /// A sentence being made holds its own reference, so the model is freed once that sentence is done.
    func unload() {
        lock.withLock {
            loaded = nil
            unspaced = nil
        }
    }

    // MARK: - Chinese and Japanese

    private func synthesizeUnspaced(_ text: String, voice: String, language: ListenLanguage) async throws -> SynthesizedSpeech {
        guard isLoaded else { throw SpeechEngineError.notLoaded }
        let model: Unspaced
        if let existing = lock.withLock({ unspaced }) {
            model = existing
        } else {
            model = Unspaced(model: try await KokoroTTSModel.fromPretrained(cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.kokoroModelID), offlineMode: true))
            lock.withLock { unspaced = model }
        }
        let samples: [Float] = try await withCheckedThrowingContinuation { continuation in
            kokoroQueue.async {
                // Kokoro takes the same language names ("chinese", "japanese") as the menu.
                continuation.resume(with: Result { try model.model.synthesize(text: text, voice: voice, language: language.rawValue) })
            }
        }
        guard !samples.isEmpty else { throw SpeechEngineError.noAudio }
        return SynthesizedSpeech(samples: samples, sampleRate: KokoroTTSModel.outputSampleRate, wordTimes: nil)
    }

    // MARK: - Running the model

    /// Kokoro's padding token, which is also what upstream Kokoro starts and ends every utterance with.
    static let padID = 0
    /// The token for a space between words.
    static let spaceID = 16
    static let inputSlots = 128
    /// The 5-second graph's output (120,000 samples); speech reaching its last 200 ms ran out of room.
    static let outputCapacity = 120_000
    static let outputTailGuard = 4_800
    /// Kokoro's durations count frames of 600 samples (25 ms).
    static let samplesPerFrame = 600

    /// Each unit's tokens (no start, end or space tokens). Tokenizing the whole sentence keeps the context words are
    /// pronounced in (a heteronym's part of speech, "a" as a determiner); its spaces then mark where units start.
    /// When the counts don't line up (a contraction spoken as two words), each unit is tokenized on its own.
    static func unitTokens(_ units: [String], text: String, tokenize: (String) -> [Int]) -> [[Int]] {
        let whole = Array(tokenize(units.joined(separator: " ")).dropFirst().dropLast())
        let runs = whole.split(separator: spaceID, omittingEmptySubsequences: false).map(Array.init)
        if runs.count == units.count { return runs }
        return units.map { Array(tokenize($0).dropFirst().dropLast()) }
    }

    private static func render(_ range: Range<Int>, units: [String], tokens: [[Int]], model: MLModel, voice: [Float], depth: Int) throws -> [KokoroPieces.Piece] {
        try Task.checkCancellation()
        let ids = KokoroPieces.ids(for: range, tokens: tokens)
        if ids.count <= inputSlots {
            let pass = try run(tokens: ids, model: model, voice: voice)
            let overran = pass.length > outputCapacity - outputTailGuard
            if !overran || range.count < 2 || depth >= 4 {
                return [KokoroPieces.Piece(units: range, tokens: Array(tokens[range]), audio: pass.audio, durations: pass.durations)]
            }
        }
        guard range.count >= 2 else {
            // One unit longer than the model takes: keep what fits.
            let clipped = Array(ids.prefix(inputSlots - 1)) + [padID]
            let pass = try run(tokens: clipped, model: model, voice: voice)
            return [KokoroPieces.Piece(units: range, tokens: Array(tokens[range]), audio: pass.audio, durations: pass.durations)]
        }
        // Too long for one pass after all: split it in two, at a pause if there's one near the middle.
        let halves = KokoroPieces.plan(units: Array(units[range]), tokens: Array(tokens[range]), budget: (ids.count + 1) / 2 + 2)
            .map { ($0.lowerBound + range.lowerBound)..<($0.upperBound + range.lowerBound) }
        let parts = halves.count >= 2 ? halves : [range.lowerBound..<(range.lowerBound + range.count / 2), (range.lowerBound + range.count / 2)..<range.upperBound]
        return try parts.flatMap { try render($0, units: units, tokens: tokens, model: model, voice: voice, depth: depth + 1) }
    }

    /// One pass of the model: the audio, how many samples of it are speech, and each token's duration in frames.
    static func run(tokens: [Int], model: MLModel, voice: [Float]) throws -> (audio: [Float], length: Int, durations: [Int]) {
        let count = min(tokens.count, inputSlots)
        let ids = try MLMultiArray(shape: [1, NSNumber(value: inputSlots)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: inputSlots)], dataType: .int32)
        for index in 0..<inputSlots {
            ids[index] = NSNumber(value: index < count ? tokens[index] : padID)
            mask[index] = NSNumber(value: index < count ? 1 : 0)
        }
        let style = try MLMultiArray(shape: [1, NSNumber(value: voice.count)], dataType: .float32)
        for (index, value) in voice.enumerated() { style[index] = NSNumber(value: value) }
        let phases = try MLMultiArray(shape: [1, 9], dataType: .float32)
        for index in 0..<9 { phases[index] = NSNumber(value: Float.random(in: 0..<1)) }
        let speed = try MLMultiArray(shape: [1], dataType: .float32)
        speed[0] = 1

        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: mask),
            "ref_s": MLFeatureValue(multiArray: style),
            "random_phases": MLFeatureValue(multiArray: phases),
            "speed": MLFeatureValue(multiArray: speed),
        ]))
        guard let audio = output.featureValue(for: "audio")?.multiArrayValue,
              let length = output.featureValue(for: "audio_length_samples")?.multiArrayValue,
              let durations = output.featureValue(for: "pred_dur")?.multiArrayValue
        else { throw SpeechEngineError.noAudio }
        let samples = min(max(length[0].intValue, 0), audio.count)
        return (
            (0..<samples).map { audio[$0].floatValue },
            samples,
            (0..<count).map { max(durations[$0].intValue, 0) }
        )
    }

    private static func loadVoices(in directory: URL) throws -> [String: [Float]] {
        let folder = directory.appendingPathComponent("voices", isDirectory: true)
        var voices: [String: [Float]] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let embedding = json["embedding"] as? [Double]
            else { continue }
            voices[file.deletingPathExtension().lastPathComponent] = embedding.prefix(256).map { Float($0) }
        }
        return voices
    }
}

// MARK: - Pieces

/// How a sentence is cut into pieces the model can make in one pass, and how the pieces are joined back up.
/// A unit is a run of the spoken text between spaces, usually one word with its punctuation.
enum KokoroPieces {
    /// Tokens per piece, start and end tokens included: about what fits in 5 seconds at Kokoro's pace (speech-swift
    /// found the same).
    static let tokenBudget = 56
    /// Pause marks a piece can end on and still sound like the sentence goes on.
    static let pauseMarks = CharacterSet(charactersIn: ",;:—–")

    /// The tokens one pass is given: the units' tokens with spaces between them, between padding tokens.
    static func ids(for range: Range<Int>, tokens: [[Int]]) -> [Int] {
        var ids = [KokoroSynthesizer.padID]
        for index in range {
            if index > range.lowerBound { ids.append(KokoroSynthesizer.spaceID) }
            ids += tokens[index]
        }
        return ids + [KokoroSynthesizer.padID]
    }

    /// Cuts the units into pieces of at most `budget` tokens: as few as it can, ending each on a pause where one is
    /// near, and without a stub of a word or two at the end.
    static func plan(units: [String], tokens: [[Int]], budget: Int = tokenBudget) -> [Range<Int>] {
        let count = units.count
        guard count > 0 else { return [] }
        func size(_ range: Range<Int>) -> Int { ids(for: range, tokens: tokens).count }
        if size(0..<count) <= budget { return [0..<count] }

        // Cheapest way to cut the first `end` units, and where its last piece starts.
        var cost = [Double](repeating: .infinity, count: count + 1)
        var cut = [Int](repeating: 0, count: count + 1)
        cost[0] = 0
        for end in 1...count {
            for start in stride(from: end - 1, through: 0, by: -1) {
                let tokens = size(start..<end)
                // A single unit always fits on its own; it's clipped if it must be.
                if tokens > budget, end - start > 1 { break }
                guard cost[start] < .infinity else { continue }
                var piece = 100.0
                if end < count, !endsOnPause(units[end - 1]) { piece += startsClause(units[end]) ? 20 : 40 }
                if tokens < 14 { piece += 50 }
                if cost[start] + piece < cost[end] {
                    cost[end] = cost[start] + piece
                    cut[end] = start
                }
            }
        }
        var ranges: [Range<Int>] = []
        var end = count
        while end > 0 {
            ranges.append(cut[end]..<end)
            end = cut[end]
        }
        return ranges.reversed()
    }

    /// English words a phrase often starts with, so cutting before one (when there's no pause mark) breaks the
    /// sentence where a reader might breathe.
    static let clauseWords: Set<String> = [
        "and", "but", "or", "nor", "so", "yet", "that", "which", "who", "whom", "whose", "where", "when", "while",
        "because", "although", "though", "if", "unless", "until", "since", "as", "from", "to", "with", "without",
        "into", "of", "for", "in", "on", "at", "by", "about", "than", "after", "before", "through",
    ]

    static func startsClause(_ unit: String) -> Bool {
        clauseWords.contains(unit.lowercased().trimmingCharacters(in: .punctuationCharacters))
    }

    static func endsOnPause(_ unit: String) -> Bool {
        guard let last = unit.unicodeScalars.last else { return false }
        return pauseMarks.contains(last)
    }

    /// A piece the model made: its units and their tokens, its audio, and each token's duration in frames (laid
    /// out as `ids(for:)` gives them).
    struct Piece {
        let units: Range<Int>
        let tokens: [[Int]]
        let audio: [Float]
        let durations: [Int]
    }

    static let sampleRate = 24_000.0
    /// Silence kept before the first word of a sentence, and before the first word of a later piece.
    static let sentenceLeadIn = 0.12
    static let pieceLeadIn = 0.02
    /// Longest pause kept after a piece's last word: at a comma mid-sentence, and at the end of the sentence.
    static let piecePause = 0.16
    static let sentencePause = 0.35
    /// Kept after a word with no punctuation, for the sound to die away.
    static let wordTail = 0.06
    /// Longest silence inside a sentence: about a comma's pause when reading aloud.
    static let longestPause = 0.3

    /// Where a piece's units sit among its tokens: each one's first token, the token after its last, and the token
    /// after its last sound that isn't punctuation. Punctuation and quote marks are tokens 1 to 15.
    static func layout(of tokens: [[Int]]) -> [(first: Int, end: Int, speechEnd: Int)] {
        var position = 1
        return tokens.map { unit in
            let first = position
            let end = first + unit.count
            let trailing = unit.reversed().prefix { (1...15).contains($0) }.count
            position = end + 1
            return (first, end, end - trailing)
        }
    }

    /// The pieces joined into the sentence's audio, and each unit's time in it.
    static func join(_ pieces: [Piece], units: [String]) -> (samples: [Float], words: [AlignedWordTime]) {
        var samples: [Float] = []
        var words: [AlignedWordTime] = []
        for (number, piece) in pieces.enumerated() {
            // Where each token starts, in samples.
            var starts = [0]
            for duration in piece.durations { starts.append(starts.last! + duration * KokoroSynthesizer.samplesPerFrame) }
            func at(_ token: Int) -> Int { min(starts[min(token, starts.count - 1)], piece.audio.count) }

            let layout = layout(of: piece.tokens)
            guard let first = layout.first, let last = layout.last else { continue }
            let isFirst = number == 0
            let isLast = number == pieces.count - 1
            let keepFrom = max(0, at(first.first) - Int((isFirst ? sentenceLeadIn : pieceLeadIn) * sampleRate))
            let lastWordEnd = at(last.speechEnd)
            // The pause the voice gave the closing punctuation, up to a natural length.
            let pause = min(at(last.end) - lastWordEnd, Int((isLast ? sentencePause : piecePause) * sampleRate))
            let keepTo = min(piece.audio.count, max(lastWordEnd + max(pause, Int(wordTail * sampleRate)), keepFrom))

            var kept = Array(piece.audio[keepFrom..<keepTo])
            fade(&kept, fadeIn: !isFirst)
            let offset = samples.count - keepFrom
            func time(_ sample: Int) -> Double {
                Double(min(max(sample + offset, samples.count), samples.count + kept.count)) / sampleRate
            }
            for (index, place) in zip(piece.units, layout) {
                words.append(AlignedWordTime(text: units[index], start: time(at(place.first)), end: time(at(place.end))))
            }
            samples += kept
        }
        return (samples, words)
    }

    private static func fade(_ samples: inout [Float], fadeIn: Bool) {
        let fadeOut = min(samples.count, 240)
        if fadeOut >= 2 {
            for index in 0..<fadeOut { samples[samples.count - fadeOut + index] *= Float(fadeOut - 1 - index) / Float(fadeOut - 1) }
        }
        if fadeIn {
            let count = min(samples.count, 120)
            if count >= 2 { for index in 0..<count { samples[index] *= Float(index) / Float(count) } }
        }
        for index in samples.indices { samples[index] = min(1, max(-1, samples[index])) }
    }
}
