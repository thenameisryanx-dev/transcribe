import AudioCommon
import Foundation
import KokoroTTS
import NaturalLanguage
import Qwen3ASR
import Qwen3TTS

// The Listen pane talks to a voice and an aligner only through these two protocols, so either can be swapped for
// another model (another speech-swift engine, the system voices, a cloud voice) without touching the reader.

/// Turns text into speech.
protocol SpeechSynthesizer: AnyObject, Sendable {
    /// Names the model and its settings; part of the key sentences are saved under, so a new model never reuses
    /// another's audio.
    var identifier: String { get }
    var isLoaded: Bool { get }
    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws
    func synthesize(_ text: String, voice: String, language: ListenLanguage) async throws -> SynthesizedSpeech
    func unload()
}

/// A voice's speech for a text. A voice that knows when it spoke each word (as Kokoro does) gives `wordTimes`, one
/// per run of the text between spaces; otherwise the aligner listens for them.
struct SynthesizedSpeech: Sendable {
    var samples: [Float]
    var sampleRate: Int
    var wordTimes: [AlignedWordTime]?
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

/// The voice models Listen reads with. Each has its own voices and languages; the word timing, playback and
/// highlighting are the same for both.
enum ListenEngine: String, CaseIterable, Identifiable, Sendable {
    /// Kokoro-82M on the Neural Engine (Core ML): makes speech several times faster than it plays on any Apple
    /// silicon Mac.
    case kokoro
    /// Qwen3-TTS 0.6B on the GPU (MLX): more expressive, but it makes speech one step at a time, so on a Mac without
    /// a lot of GPU memory bandwidth (a base M-series chip) it's slower than the speech plays.
    case qwen

    static let defaultEngine = ListenEngine.kokoro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .qwen: return "Qwen3-TTS"
        }
    }

    var summary: String {
        switch self {
        case .kokoro: return "Fast"
        case .qwen: return "More expressive, slow on most Macs"
        }
    }

    var voices: [ListenVoice] {
        switch self {
        case .kokoro: return ListenVoice.kokoro
        case .qwen: return ListenVoice.qwen
        }
    }

    var defaultVoiceID: String {
        switch self {
        case .kokoro: return "af_heart"
        case .qwen: return "ryan"
        }
    }

    /// The languages it can read, in menu order, `automatic` first.
    var languages: [ListenLanguage] {
        switch self {
        // Kokoro also has Hindi voices, but the word aligner doesn't know Hindi; it reads German, Korean and
        // Russian only with English sounds.
        case .kokoro: return [.automatic, .english, .chinese, .japanese, .french, .spanish, .italian, .portuguese]
        case .qwen: return ListenLanguage.allCases
        }
    }

    func reads(_ language: ListenLanguage) -> Bool {
        languages.contains(language)
    }

    func voice(_ id: String) -> ListenVoice? {
        voices.first { $0.id == id }
    }

    /// About how many seconds it takes to make a second of speech and time its words, until the reader has measured
    /// it on this Mac. Qwen3-TTS takes about 1.35 on a base M4 (`ListenBenchmarkTests`).
    var expectedMakingRate: Double {
        switch self {
        case .kokoro: return 0.3
        case .qwen: return 1.35
        }
    }

    /// The models it downloads, the word aligner included.
    var modelIDs: [String] {
        switch self {
        case .kokoro: return [SpeechModelFiles.kokoroModelID, SpeechModelFiles.alignerModelID]
        case .qwen: return [SpeechModelFiles.ttsModelID, SpeechModelFiles.ttsTokenizerID, SpeechModelFiles.alignerModelID]
        }
    }

    /// What its downloads add up to (the aligner included), for telling people before they start.
    var approximateDownloadSize: Int64 {
        switch self {
        case .kokoro: return 1_320_000_000
        case .qwen: return 3_480_000_000
        }
    }
}

/// A voice of one of the engines. Any voice can read any of its engine's languages; each sounds most natural in its
/// own.
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

    /// Kokoro's voices, named as in its download: the first letter is the language (and for English the accent),
    /// the second whether the voice is female or male. Its Hindi voices are left out (see `ListenEngine.languages`).
    static let kokoro: [ListenVoice] = [
        "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river",
        "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
        "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george",
        "bm_lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis", "if_sara", "im_nicola", "jf_alpha",
        "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei",
        "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
    ].compactMap(kokoroVoice)

    static func kokoroVoice(_ id: String) -> ListenVoice? {
        let parts = id.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2 else { return nil }
        let codes = Array(parts[0])
        let languages: [Character: (ListenLanguage, String?)] = [
            "a": (.english, "American"), "b": (.english, "British"), "e": (.spanish, nil), "f": (.french, nil),
            "i": (.italian, nil), "j": (.japanese, nil), "p": (.portuguese, nil), "z": (.chinese, nil),
        ]
        guard let (language, accent) = languages[codes[0]], codes[1] == "f" || codes[1] == "m" else { return nil }
        let gender = codes[1] == "f" ? "Female" : "Male"
        return ListenVoice(
            id: id,
            name: parts[1].prefix(1).uppercased() + parts[1].dropFirst(),
            summary: [gender, accent].compactMap { $0 }.joined(separator: ", "),
            nativeLanguage: language
        )
    }
}

// MARK: - Model files

/// Where the downloaded speech models live: `~/Library/Application Support/LectureTranscribe/SpeechModels`. Not in
/// Caches, so macOS never clears a multi-gigabyte download on its own.
enum SpeechModelFiles {
    static let kokoroModelID = KokoroTTSModel.defaultModelId
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

    /// Whether all of an engine's models are on disk (they may still need loading).
    static func isDownloaded(for engine: ListenEngine) -> Bool {
        engine.modelIDs.allSatisfy { id in
            guard let directory = try? directory(for: id) else { return false }
            // Kokoro is a compiled Core ML model rather than a weights file.
            if id == kokoroModelID {
                return FileManager.default.fileExists(atPath: directory.appendingPathComponent("kokoro_5s.mlmodelc").path)
                    && FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocab_index.json").path)
            }
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
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
        mlxQueue.async {
            continuation.resume(with: Result { try MLXWorkGate.shared.run(work) })
        }
    }
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

    func synthesize(_ text: String, voice: String, language: ListenLanguage) async throws -> SynthesizedSpeech {
        let box = box
        let samples = try await onMLXQueue {
            guard let model = box.value else { throw SpeechEngineError.notLoaded }
            return model.synthesize(text: text, language: language.rawValue, speaker: voice, languageExplicit: true)
        }
        guard !samples.isEmpty else { throw SpeechEngineError.noAudio }
        return SynthesizedSpeech(samples: samples, sampleRate: 24_000, wordTimes: nil)
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

// MARK: - Speaking a sentence

/// Speaks a sentence and times its words: the voice makes the audio and, unless it timed the words itself, the
/// aligner listens to it.
struct SentenceSpeaker: Sendable {
    let synthesizer: any SpeechSynthesizer
    let aligner: any WordAligner

    var identifier: String { "\(synthesizer.identifier)+\(aligner.identifier)" }

    func speak(_ sentence: ReadingSentence, voice: String, language: ListenLanguage) async throws -> SpokenSentence {
        let audio = try await synthesizer.synthesize(sentence.spokenText, voice: voice, language: language)
        try Task.checkCancellation()
        let duration = Double(audio.samples.count) / Double(audio.sampleRate)
        let words = sentence.words.map(\.text)
        if let known = audio.wordTimes {
            let times = WordTimingMatcher.timings(for: words, aligned: known, duration: duration)
            return SpokenSentence(samples: audio.samples, sampleRate: audio.sampleRate, wordTimes: times)
        }
        // A sentence still plays if timing fails; its words are then spread over it by length.
        let aligned = (try? await aligner.align(samples: audio.samples, sampleRate: audio.sampleRate, text: sentence.spokenText, language: language)) ?? []
        // The aligner tends to start the word after a pause where the pause begins.
        let times = SpeechPauses.movingStarts(
            of: WordTimingMatcher.timings(for: words, aligned: aligned, duration: duration),
            outOf: SpeechPauses.find(in: audio.samples, sampleRate: audio.sampleRate),
            words: words,
            duration: duration
        )
        return SpokenSentence(samples: audio.samples, sampleRate: audio.sampleRate, wordTimes: times)
    }
}
