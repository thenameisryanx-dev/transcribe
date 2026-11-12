import AudioCommon
import Foundation
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
    func synthesize(_ text: String, voice: String, language: ListenLanguage) async throws -> (samples: [Float], sampleRate: Int)
    func unload()
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

/// The voices built into Qwen3-TTS CustomVoice. Any voice can read any language; each sounds most natural in its
/// own.
struct ListenVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let nativeLanguage: ListenLanguage

    static let all: [ListenVoice] = [
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

    static let defaultID = "ryan"

    static func named(_ id: String) -> ListenVoice {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Model files

/// Where the downloaded speech models live: `~/Library/Application Support/LectureTranscribe/SpeechModels`. Not in
/// Caches, so macOS never clears a 3.5 GB download on its own.
enum SpeechModelFiles {
    static let ttsModelID = "aufklarer/Qwen3-TTS-12Hz-0.6B-CustomVoice-MLX-bf16"
    static let ttsTokenizerID = "Qwen/Qwen3-TTS-Tokenizer-12Hz"
    static let alignerModelID = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"
    /// What the three downloads add up to, for telling people before they start.
    static let approximateDownloadSize: Int64 = 3_480_000_000

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

    /// Whether all three models are on disk (they may still need loading).
    static var isDownloaded: Bool {
        [ttsModelID, ttsTokenizerID, alignerModelID].allSatisfy { id in
            (try? directory(for: id)).map(HuggingFaceDownloader.weightsExist(in:)) ?? false
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
            continuation.resume(with: Result { try work() })
        }
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
}

enum SpeechEngineError: LocalizedError {
    case notLoaded
    case noAudio

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "The voice isn't loaded yet."
        case .noAudio: return "The voice didn't produce any audio for this sentence."
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
        let model = try await Qwen3TTSModel.fromPretrained(
            modelId: SpeechModelFiles.ttsModelID,
            tokenizerModelId: SpeechModelFiles.ttsTokenizerID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsModelID),
            tokenizerCacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsTokenizerID),
            progressHandler: { fraction, message in progress(fraction, message) }
        )
        box.value = model
    }

    func synthesize(_ text: String, voice: String, language: ListenLanguage) async throws -> (samples: [Float], sampleRate: Int) {
        let box = box
        let samples = try await onMLXQueue {
            guard let model = box.value else { throw SpeechEngineError.notLoaded }
            return model.synthesize(text: text, language: language.rawValue, speaker: voice, languageExplicit: true)
        }
        guard !samples.isEmpty else { throw SpeechEngineError.noAudio }
        return (samples, 24_000)
    }

    func unload() {
        box.value = nil
    }
}

/// Qwen3-ForcedAligner 0.6B (4-bit): word times for any speech and its text, whatever voice made it.
final class Qwen3Aligner: WordAligner, @unchecked Sendable {
    let identifier = "qwen3-aligner|\(SpeechModelFiles.alignerModelID)"
    private let box = ModelBox<Qwen3ForcedAligner>()

    var isLoaded: Bool { box.value != nil }

    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard box.value == nil else { return }
        let aligner = try await Qwen3ForcedAligner.fromPretrained(
            modelId: SpeechModelFiles.alignerModelID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.alignerModelID),
            progressHandler: { fraction, message in progress(fraction, message) }
        )
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
        box.value = nil
    }
}

// MARK: - Speaking a sentence

/// Speaks a sentence and times its words: the voice makes the audio, then the aligner listens to it.
struct SentenceSpeaker: Sendable {
    let synthesizer: any SpeechSynthesizer
    let aligner: any WordAligner

    var identifier: String { "\(synthesizer.identifier)+\(aligner.identifier)" }

    func speak(_ sentence: ReadingSentence, voice: String, language: ListenLanguage) async throws -> SpokenSentence {
        let audio = try await synthesizer.synthesize(sentence.spokenText, voice: voice, language: language)
        try Task.checkCancellation()
        let duration = Double(audio.samples.count) / Double(audio.sampleRate)
        // A sentence still plays if timing fails; its words are then spread over it by length.
        let aligned = (try? await aligner.align(samples: audio.samples, sampleRate: audio.sampleRate, text: sentence.spokenText, language: language)) ?? []
        let times = WordTimingMatcher.timings(for: sentence.words.map(\.text), aligned: aligned, duration: duration)
        return SpokenSentence(samples: audio.samples, sampleRate: audio.sampleRate, wordTimes: times)
    }
}
