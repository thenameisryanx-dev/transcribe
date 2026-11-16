import AudioCommon
import Foundation
import NaturalLanguage
import Qwen3ASR
import Qwen3TTSLocal

// The Listen pane talks to a voice and an aligner only through these two protocols, so either can be swapped for
// another model (another speech-swift engine, the system voices, a cloud voice) without touching the reader.

/// Turns text into speech, several texts at once.
protocol SpeechSynthesizer: AnyObject, Sendable {
    /// Names the model and its settings; part of the key sentences are saved under, so a new model never reuses
    /// another's audio.
    var identifier: String { get }
    var isLoaded: Bool { get }
    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws
    /// Speaks each of `texts` in one voice, returning them in order. Making several at once is much faster than one
    /// after another (see `Qwen3TTSModel.synthesizeVoiceBatch`). Throws `CancellationError` soon after the task is
    /// cancelled.
    func synthesize(_ texts: [String], voice: String, language: ListenLanguage) async throws -> [SynthesizedSpeech]
    func unload()
}

/// A voice's speech for a text.
struct SynthesizedSpeech: Sendable {
    var samples: [Float]
    var sampleRate: Int
}

/// Finds when each word of a text is spoken in a recording of it.
protocol WordAligner: AnyObject, Sendable {
    var identifier: String { get }
    var isLoaded: Bool { get }
    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws
    func align(samples: [Float], sampleRate: Int, text: String, language: ListenLanguage) async throws -> [AlignedWordTime]
    func unload()
}

// MARK: - Languages and voices

/// The languages Qwen3-TTS speaks. `automatic` picks one from the text.
enum ListenLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case english, chinese, japanese, korean, german, french, spanish, italian, portuguese, russian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// The language to speak `text` in: this one, or for `automatic` the text's own language when it's one of
    /// these (English otherwise).
    func resolved(for text: String) -> ListenLanguage {
        guard self == .automatic else { return self }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        let byCode: [NLLanguage: ListenLanguage] = [
            .english: .english, .simplifiedChinese: .chinese, .traditionalChinese: .chinese, .japanese: .japanese,
            .korean: .korean, .german: .german, .french: .french, .spanish: .spanish, .italian: .italian,
            .portuguese: .portuguese, .russian: .russian,
        ]
        return recognizer.dominantLanguage.flatMap { byCode[$0] } ?? .english
    }
}

/// The voice model Listen reads with: Qwen3-TTS 0.6B CustomVoice on the GPU (MLX), timed by Qwen3-ForcedAligner.
enum ListenVoiceModel {
    static let displayName = "Qwen3-TTS"
    static let defaultVoiceID = "ryan"
    static var voices: [ListenVoice] { ListenVoice.qwen }
    /// The languages it reads, in menu order, `automatic` first.
    static let languages = ListenLanguage.allCases

    static func voice(_ id: String) -> ListenVoice? {
        voices.first { $0.id == id }
    }

    /// The models it downloads, the word aligner included.
    static let modelIDs = [SpeechModelFiles.ttsModelID, SpeechModelFiles.ttsTokenizerID, SpeechModelFiles.alignerModelID]

    /// What its downloads add up to, for telling people before they start.
    static let approximateDownloadSize: Int64 = 3_480_000_000

    /// How many sentences it makes at once on a Mac with this much memory. Each extra sentence needs little memory
    /// (about 25 MB); the limit is the GPU, which gets busier for everything else. On a base M4 with 16 GB, 8 at
    /// once make speech about 3.5 times as fast as one at a time (`ListenBenchmarkTests`).
    static func defaultSentencesAtOnce(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let gigabytes = physicalMemory / 1_073_741_824
        if gigabytes >= 15 { return 8 }
        if gigabytes >= 8 { return 4 }
        return 2
    }

    static let sentencesAtOnceChoices = [1, 2, 4, 6, 8]
}

/// A voice of the voice model. Any voice can read any language; each sounds most natural in its own.
struct ListenVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let nativeLanguage: ListenLanguage

    /// The voices built into Qwen3-TTS CustomVoice.
    static let qwen: [ListenVoice] = [
        ListenVoice(id: "ryan", name: "Ryan", summary: "Male, energetic", nativeLanguage: .english),
        ListenVoice(id: "aiden", name: "Aiden", summary: "Male, bright American", nativeLanguage: .english),
        ListenVoice(id: "vivian", name: "Vivian", summary: "Female, bright", nativeLanguage: .chinese),
        ListenVoice(id: "serena", name: "Serena", summary: "Female, warm and gentle", nativeLanguage: .chinese),
        ListenVoice(id: "uncle_fu", name: "Uncle Fu", summary: "Male, low and mellow", nativeLanguage: .chinese),
        ListenVoice(id: "dylan", name: "Dylan", summary: "Male, Beijing accent", nativeLanguage: .chinese),
        ListenVoice(id: "eric", name: "Eric", summary: "Male, Sichuan accent", nativeLanguage: .chinese),
        ListenVoice(id: "ono_anna", name: "Ono Anna", summary: "Female, playful", nativeLanguage: .japanese),
        ListenVoice(id: "sohee", name: "Sohee", summary: "Female, warm", nativeLanguage: .korean),
    ]
}

// MARK: - Model files

/// Where the downloaded speech models live: `~/Library/Application Support/LectureTranscribe/SpeechModels`. Not in
/// Caches, so macOS never clears a multi-gigabyte download on its own.
enum SpeechModelFiles {
    static let ttsModelID = "aufklarer/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-bf16"
    static let ttsTokenizerID = "Qwen/Qwen3-TTS-Tokenizer-12Hz"
    static let alignerModelID = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"

    static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("LectureTranscribe", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
    }

    static func directory(for modelID: String) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: modelID, basePath: root)
    }

    /// Whether all of the voice model's files are on disk (they may still need loading).
    static func isDownloaded() -> Bool {
        ListenVoiceModel.modelIDs.allSatisfy { id in
            guard let directory = try? directory(for: id) else { return false }
            return HuggingFaceDownloader.weightsExist(in: directory)
        }
    }

    static func size() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func removeAll() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }
}

// MARK: - Qwen3 (speech-swift, MLX)

/// The models run on the GPU and aren't safe to use from two threads at once, so the voice and the aligner share
/// one serial queue. Running them there also keeps seconds-long GPU work off Swift's shared threads.
private let mlxQueue = DispatchQueue(label: "LectureTranscribe.Listen.MLX", qos: .userInitiated)

private func onMLXQueue<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await onMLXQueue { _ in try work() }
}

/// Runs `work` on the MLX queue; `isCancelled` turns true once the calling task is cancelled, so long work can stop
/// between steps.
private func onMLXQueue<T>(_ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T) async throws -> T {
    try Task.checkCancellation()
    let cancelled = CancellationFlag()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            mlxQueue.async {
                continuation.resume(with: Result { try MLXWorkGate.shared.run { try work { cancelled.isSet } } })
            }
        }
    } onCancel: {
        cancelled.set()
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Counts the MLX work running (a model loading, a sentence being spoken) so the app can wait for it before it
/// quits. `exit()` destroys MLX's C++ statics, its compile cache among them, so quitting while a sentence was being
/// spoken crashed the thread still using that cache.
final class MLXWorkGate: @unchecked Sendable {
    static let shared = MLXWorkGate()

    private let lock = NSLock()
    private var running = 0
    private var closed = false
    private var whenIdle: [@Sendable () -> Void] = []

    /// Runs `work`, or throws `CancellationError` without running it once the gate is closed.
    func run<T>(_ work: () throws -> T) throws -> T {
        try enter()
        defer { leave() }
        return try work()
    }

    func run<T>(_ work: () async throws -> T) async throws -> T {
        try enter()
        defer { leave() }
        return try await work()
    }

    /// Lets no more work start. Returns true when nothing is running; otherwise `whenIdle` is called, on the thread
    /// that finishes it, once the work already running is done.
    func close(whenIdle: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            closed = true
            guard running > 0 else { return true }
            self.whenIdle.append(whenIdle)
            return false
        }
    }

    private func enter() throws {
        try lock.withLock {
            if closed { throw CancellationError() }
            running += 1
        }
    }

    private func leave() {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            running -= 1
            guard running == 0 else { return [] }
            defer { whenIdle = [] }
            return whenIdle
        }
        callbacks.forEach { $0() }
    }
}

/// Holds a model that isn't Sendable. Only touched on `mlxQueue` (and while loading, before anything else can
/// reach it).
private final class ModelBox<Model>: @unchecked Sendable {
    private let lock = NSLock()
    private var model: Model?

    var value: Model? {
        get { lock.withLock { model } }
        set { lock.withLock { model = newValue } }
    }

    /// Frees the model on `mlxQueue`. Freeing it removes its compiled graphs from MLX's compile cache, which must
    /// not happen while the other model is using that cache there.
    func release() {
        let old = ModelBox()
        lock.withLock {
            old.model = model
            model = nil
        }
        mlxQueue.async {
            // Once the app is quitting the model stays until the process ends.
            try? MLXWorkGate.shared.run { old.value = nil }
        }
    }
}

enum SpeechEngineError: LocalizedError {
    case notLoaded
    case noAudio
    case noVoice(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "The voice isn't loaded yet."
        case .noAudio: return "The voice didn't produce any audio for this sentence."
        case .noVoice(let voice): return "The voice “\(voice)” isn't in the downloaded voice model."
        }
    }
}

/// Qwen3-TTS 0.6B CustomVoice: nine built-in voices, ten languages, 24 kHz audio.
final class Qwen3Synthesizer: SpeechSynthesizer, @unchecked Sendable {
    let identifier = "qwen3-tts|\(SpeechModelFiles.ttsModelID)"
    private let box = ModelBox<Qwen3TTSModel>()

    var isLoaded: Bool { box.value != nil }

    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard box.value == nil else { return }
        // Waits for a model being freed on the MLX queue, since loading compiles graphs into the same cache.
        try await onMLXQueue {}
        let model = try await MLXWorkGate.shared.run { try await Qwen3TTSModel.fromPretrained(
            modelId: SpeechModelFiles.ttsModelID,
            tokenizerModelId: SpeechModelFiles.ttsTokenizerID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsModelID),
            tokenizerCacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsTokenizerID),
            progressHandler: { fraction, message in progress(fraction, message) }
        ) }
        box.value = model
    }

    func synthesize(_ texts: [String], voice: String, language: ListenLanguage) async throws -> [SynthesizedSpeech] {
        let box = box
        let made = try await onMLXQueue { isCancelled in
            guard let model = box.value else { throw SpeechEngineError.notLoaded }
            return try model.synthesizeVoiceBatch(texts: texts, language: language.rawValue, speaker: voice) {
                if isCancelled() { throw CancellationError() }
            }
        }
        return made.map { SynthesizedSpeech(samples: $0, sampleRate: 24_000) }
    }

    func unload() {
        box.release()
    }
}

/// Qwen3-ForcedAligner 0.6B (4-bit): word times for any speech and its text, whatever voice made it.
final class Qwen3Aligner: WordAligner, @unchecked Sendable {
    let identifier = "qwen3-aligner|\(SpeechModelFiles.alignerModelID)"
    private let box = ModelBox<Qwen3ForcedAligner>()

    var isLoaded: Bool { box.value != nil }

    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard box.value == nil else { return }
        try await onMLXQueue {}
        let aligner = try await MLXWorkGate.shared.run { try await Qwen3ForcedAligner.fromPretrained(
            modelId: SpeechModelFiles.alignerModelID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.alignerModelID),
            progressHandler: { fraction, message in progress(fraction, message) }
        ) }
        box.value = aligner
    }

    func align(samples: [Float], sampleRate: Int, text: String, language: ListenLanguage) async throws -> [AlignedWordTime] {
        let box = box
        return try await onMLXQueue {
            guard let aligner = box.value else { throw SpeechEngineError.notLoaded }
            return aligner.align(audio: samples, text: text, sampleRate: sampleRate, language: language.displayName)
                .map { AlignedWordTime(text: $0.text, start: Double($0.startTime), end: Double($0.endTime)) }
        }
    }

    func unload() {
        box.release()
    }
}

// MARK: - Speaking sentences

/// Speaks sentences and times their words: the voice makes the audio, several sentences at once, and the aligner
/// listens to each for when its words are said.
struct SentenceSpeaker: Sendable {
    let synthesizer: any SpeechSynthesizer
    let aligner: any WordAligner

    /// Part of the key sentences are saved under. `spoken-numbers` marks speech made with numbers written out as
    /// words (`SpokenNumbers`), so sentences saved before, with numbers that were never highlighted in time, are
    /// made again.
    var identifier: String { "\(synthesizer.identifier)+\(aligner.identifier)+spoken-numbers" }

    func speak(_ sentences: [ReadingSentence], voice: String, language: ListenLanguage) async throws -> [SpokenSentence] {
        let texts = sentences.map { $0.voiceText(in: language) }
        let audio = try await synthesizer.synthesize(texts, voice: voice, language: language)
        guard audio.count == sentences.count else { throw SpeechEngineError.noAudio }
        var spoken: [SpokenSentence] = []
        for (index, sentence) in sentences.enumerated() {
            try Task.checkCancellation()
            var speech = audio[index]
            if speech.samples.isEmpty {
                // Rarely the voice ends a sentence before saying anything. A short silence keeps the reading going
                // (its words are highlighted in turn) rather than losing the whole document over it.
                speech.samples = [Float](repeating: 0, count: speech.sampleRate / 2)
            }
            // A sentence still plays if timing fails; its words are then spread over it by length.
            let aligned = (try? await aligner.align(samples: speech.samples, sampleRate: speech.sampleRate, text: texts[index], language: language)) ?? []
            spoken.append(SpokenSentence(
                samples: speech.samples,
                sampleRate: speech.sampleRate,
                wordTimes: Self.wordTimes(for: sentence, aligned: aligned, samples: speech.samples, sampleRate: speech.sampleRate, language: language)
            ))
        }
        return spoken
    }

    /// When each of the sentence's words is said. The aligner times the words the voice said (a number is several),
    /// so each word of the sentence runs from the start of the first of its spoken words to the end of the last.
    static func wordTimes(for sentence: ReadingSentence, aligned: [AlignedWordTime], samples: [Float], sampleRate: Int, language: ListenLanguage) -> [WordTime] {
        let groups = sentence.spokenWords(in: language)
        let spokenWords = groups.flatMap { $0 }
        let duration = Double(samples.count) / Double(max(sampleRate, 1))
        // The aligner tends to start the word after a pause where the pause begins.
        let times = SpeechPauses.movingStarts(
            of: WordTimingMatcher.timings(for: spokenWords, aligned: aligned, duration: duration),
            outOf: SpeechPauses.find(in: samples, sampleRate: sampleRate),
            words: spokenWords,
            duration: duration
        )
        var result: [WordTime] = []
        var next = 0
        for group in groups {
            let first = times[next]
            let last = times[next + group.count - 1]
            result.append(WordTime(start: first.start, end: max(last.end, first.start)))
            next += group.count
        }
        return result
    }
}
