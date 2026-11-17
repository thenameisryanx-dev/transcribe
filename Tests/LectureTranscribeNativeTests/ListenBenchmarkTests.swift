import Foundation
import MLX
import Qwen3TTSLocal
import XCTest

@testable import LectureTranscribeNative

/// Measures how fast the real Qwen3-TTS voice makes speech on this Mac, as a real-time factor (seconds to make ÷
/// seconds of audio), one sentence at a time and several at once, and checks that sentences made together end on
/// their own like ones made alone. On a base M4 one at a time is about 0.9–1.3 and eight at once about 0.25. Needs
/// the Qwen3-TTS models downloaded, so it runs only when asked:
///
///     LISTEN_BENCHMARK=1 swift test --filter ListenBenchmarkTests
final class ListenBenchmarkTests: XCTestCase {
    static let text = """
    The cell membrane is a thin layer of lipids and proteins that separates the inside of the cell from its \
    surroundings. It lets some molecules pass freely, while others need a channel or a pump. Water crosses by \
    osmosis, moving toward the side with more dissolved particles. This is why a red blood cell swells in pure \
    water and shrinks in salt water. Active transport uses energy from ATP to move ions against their gradient. \
    The sodium potassium pump is the classic example, and it keeps nerve cells ready to fire. Today we will see \
    how these gradients store energy. Then we will look at how the cell spends it.
    """

    func testQwenRealTimeFactor() async throws {
        guard ProcessInfo.processInfo.environment["LISTEN_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 to measure the real voice.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let sentences = ReadingDocument(text: Self.text).sentences.map(\.spokenText)

        let model = try await Qwen3TTSModel.fromPretrained(
            modelId: SpeechModelFiles.ttsModelID,
            tokenizerModelId: SpeechModelFiles.ttsTokenizerID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsModelID),
            tokenizerCacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsTokenizerID)
        )
        let aligner = Qwen3Aligner()
        try await aligner.load { _, _ in }
        _ = model.synthesize(text: "Warming up.", language: "english", speaker: "ryan", languageExplicit: true)

        // One at a time with the library's own path: make a sentence, then time its words.
        var makeTime = 0.0, alignTime = 0.0, audio = 0.0
        for sentence in sentences {
            let start = Date()
            let samples = model.synthesize(text: sentence, language: "english", speaker: "ryan", languageExplicit: true)
            let made = Date()
            _ = try await aligner.align(samples: samples, sampleRate: 24_000, text: sentence, language: .english)
            makeTime += made.timeIntervalSince(start)
            alignTime += Date().timeIntervalSince(made)
            audio += Double(samples.count) / 24_000
        }
        print(String(format: "BENCH one-at-a-time: %d sentences, audio %.1fs, make %.1fs, align %.1fs, RTF make %.2f, RTF make+align %.2f",
                     sentences.count, audio, makeTime, alignTime, makeTime / audio, (makeTime + alignTime) / audio))
    }

    static let longerText = text + """

    Every neuron keeps more sodium outside than inside, and more potassium inside than outside. When a channel \
    opens, ions rush down their gradient and the voltage across the membrane changes. That brief change is the \
    action potential, and it travels along the axon like a wave. Myelin wraps the axon and lets the signal jump \
    from gap to gap, which makes it much faster. At the end of the axon, the signal reaches a synapse. There it \
    releases chemical messengers that cross a tiny gap to the next cell. Some messengers excite that cell, and \
    others calm it down. By the end of the week, you should be able to sketch this whole path from memory.
    """

    /// Makes the same sentences one at a time and then several at once, and checks the batch: every sentence ends
    /// by itself (none runs to its length cap, as when the batch's rows were mixed up) and speaks at a normal pace.
    func testMakingSeveralAtOnceIsFasterAndSoundsTheSame() async throws {
        guard ProcessInfo.processInfo.environment["LISTEN_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 to measure the real voice.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let sentences = Array(ReadingDocument(text: Self.longerText).sentences.prefix(8)).map(\.spokenText)
        let model = try await Qwen3TTSModel.fromPretrained(
            modelId: SpeechModelFiles.ttsModelID,
            tokenizerModelId: SpeechModelFiles.ttsTokenizerID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsModelID),
            tokenizerCacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsTokenizerID)
        )
        _ = try model.synthesizeVoiceBatch(texts: ["Warming up."], language: "english", speaker: "ryan")
        _ = try model.synthesizeVoiceBatch(texts: Array(repeating: "Warming up.", count: 8), language: "english", speaker: "ryan")

        var start = Date()
        let alone = try sentences.flatMap { try model.synthesizeVoiceBatch(texts: [$0], language: "english", speaker: "ryan") }
        let aloneTime = Date().timeIntervalSince(start)
        start = Date()
        let together = try model.synthesizeVoiceBatch(texts: sentences, language: "english", speaker: "ryan")
        let togetherTime = Date().timeIntervalSince(start)

        func seconds(_ audio: [[Float]]) -> [Double] { audio.map { Double($0.count) / 24_000 } }
        let aloneAudio = seconds(alone).reduce(0, +)
        let togetherAudio = seconds(together).reduce(0, +)
        print(String(format: "BENCH one at a time: RTF %.2f (%.1fs for %.1fs); 8 at once: RTF %.2f (%.1fs for %.1fs)",
                     aloneTime / aloneAudio, aloneTime, aloneAudio, togetherTime / togetherAudio, togetherTime, togetherAudio))
        XCTAssertLessThan(togetherTime / togetherAudio, aloneTime / aloneAudio * 0.6, "Making 8 at once isn't much faster")
        for (text, length) in zip(sentences, seconds(together)) {
            let pace = Double(text.split(separator: " ").count) / length
            // People speak about 2.5 words a second; a sentence run to its cap is well under 1.5.
            XCTAssertGreaterThan(pace, 1.4, "“\(text)” ran on (\(length)s)")
            XCTAssertLessThan(pace, 5, "“\(text)” was cut short (\(length)s)")
        }
    }

    /// Makes the same 48 sentences 8, 16, 24 and 32 at a time (48 splits evenly into each, so no size ends on a
    /// small leftover batch), longest first as Listen does, and prints how fast each
    /// is and the most GPU memory it used: where making more at once stops paying off on this Mac. Only prints; set
    /// LISTEN_BATCH_SWEEP=1 as well, since it takes a few minutes.
    func testHowManyAtOnceStopsPayingOff() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LISTEN_BENCHMARK"] == "1", environment["LISTEN_BATCH_SWEEP"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 and LISTEN_BATCH_SWEEP=1 to compare how many sentences to make at once.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let source = (ReadingDocument(text: Self.longerText).sentences + ReadingDocument(text: Self.text).sentences).map(\.spokenText)
        let sentences = (0..<48).map { source[$0 % source.count] }
            .sorted { $0.count > $1.count }
        let model = try await Qwen3TTSModel.fromPretrained(
            modelId: SpeechModelFiles.ttsModelID,
            tokenizerModelId: SpeechModelFiles.ttsTokenizerID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsModelID),
            tokenizerCacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsTokenizerID)
        )
        print("BENCH sweep: \(sentences.count) sentences, \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB, "
            + "\(ListenVoiceModel.gpuCoreCount() ?? 0) GPU cores")
        for atOnce in [8, 16, 24, 32] {
            _ = try model.synthesizeVoiceBatch(texts: Array(repeating: "Warming up.", count: atOnce), language: "english", speaker: "ryan")
            Memory.peakMemory = 0
            let start = Date()
            var audioSeconds = 0.0
            for batch in stride(from: 0, to: sentences.count, by: atOnce) {
                let texts = Array(sentences[batch..<min(batch + atOnce, sentences.count)])
                audioSeconds += try model.synthesizeVoiceBatch(texts: texts, language: "english", speaker: "ryan")
                    .reduce(0) { $0 + Double($1.count) / 24_000 }
            }
            let time = Date().timeIntervalSince(start)
            print(String(format: "BENCH %2d at once: RTF %.2f (%.1fs for %.1fs of audio), peak GPU memory %.2f GB",
                         atOnce, time / audioSeconds, time, audioSeconds, Double(Memory.peakMemory) / 1_073_741_824))
        }
    }

    /// Makes 64 sentences 48 and then 64 at a time, the largest choices, and checks every sentence still ends by itself
    /// at a normal pace, as in smaller batches; prints how fast each was and the most GPU memory it used.
    func testTheLargestBatchesStillSoundRight() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LISTEN_BENCHMARK"] == "1", environment["LISTEN_BATCH_SWEEP"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 and LISTEN_BATCH_SWEEP=1 to check the largest batches.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let source = (ReadingDocument(text: Self.longerText).sentences + ReadingDocument(text: Self.text).sentences).map(\.spokenText)
        let sentences = (0..<64).map { source[$0 % source.count] }.sorted { $0.count > $1.count }
        let model = try await Qwen3TTSModel.fromPretrained(
            modelId: SpeechModelFiles.ttsModelID,
            tokenizerModelId: SpeechModelFiles.ttsTokenizerID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsModelID),
            tokenizerCacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsTokenizerID)
        )
        for atOnce in [48, 64] {
            _ = try model.synthesizeVoiceBatch(texts: Array(repeating: "Warming up.", count: atOnce), language: "english", speaker: "ryan")
            Memory.peakMemory = 0
            let start = Date()
            var made: [(String, [Float])] = []
            for batch in stride(from: 0, to: sentences.count, by: atOnce) {
                let texts = Array(sentences[batch..<min(batch + atOnce, sentences.count)])
                made += zip(texts, try model.synthesizeVoiceBatch(texts: texts, language: "english", speaker: "ryan")).map { ($0, $1) }
            }
            let time = Date().timeIntervalSince(start)
            let audioSeconds = made.reduce(0) { $0 + Double($1.1.count) / 24_000 }
            var outside = 0
            for (text, audio) in made {
                let length = Double(audio.count) / 24_000
                let pace = Double(text.split(separator: " ").count) / length
                // As in the 8-at-once check: people speak about 2.5 words a second; a sentence run to its cap is under 1.5.
                XCTAssertGreaterThan(pace, 1.4, "\(atOnce) at once: “\(text)” ran on (\(length)s)")
                XCTAssertLessThan(pace, 5, "\(atOnce) at once: “\(text)” was cut short (\(length)s)")
                if pace <= 1.4 || pace >= 5 { outside += 1 }
            }
            print(String(format: "BENCH %d at once: RTF %.2f (%.1fs for %.1fs of audio), peak GPU memory %.2f GB, %d of %d sentences at a normal pace",
                         atOnce, time / audioSeconds, time, audioSeconds, Double(Memory.peakMemory) / 1_073_741_824,
                         made.count - outside, made.count))
        }
    }

    /// Times one batch of 32 sentences through the real voice and the real aligner, to see where preparing spends its
    /// time: the batch itself, or the aligner, which times one sentence after another.
    func testWhereTheTimeGoes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LISTEN_BENCHMARK"] == "1", environment["LISTEN_BATCH_SWEEP"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 and LISTEN_BATCH_SWEEP=1 to time a big batch.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let source = (ReadingDocument(text: Self.longerText).sentences + ReadingDocument(text: Self.text).sentences).map(\.spokenText)
        let texts = (0..<32).map { source[$0 % source.count] }
        let synthesizer = Qwen3Synthesizer()
        let aligner = Qwen3Aligner()
        try await synthesizer.load { _, _ in }
        try await aligner.load { _, _ in }
        _ = try await synthesizer.synthesize(Array(repeating: "Warming up.", count: 32), voice: "ryan", language: .english)

        var start = Date()
        let audio = try await synthesizer.synthesize(texts, voice: "ryan", language: .english)
        let synthesisTime = Date().timeIntervalSince(start)
        start = Date()
        for (text, speech) in zip(texts, audio) {
            _ = try await aligner.align(samples: speech.samples, sampleRate: speech.sampleRate, text: text, language: .english)
        }
        let alignTime = Date().timeIntervalSince(start)
        let audioSeconds = audio.reduce(0) { $0 + Double($1.samples.count) / Double($1.sampleRate) }
        print(String(format: "BENCH 32 at once: voice %.1fs, aligner %.1fs (%.2fs a sentence), for %.1fs of audio",
                     synthesisTime, alignTime, alignTime / 32, audioSeconds))
    }

    /// Prepares a document with the real voice and aligner, as Play does, then reads it through the real (muted)
    /// player to the end without stopping. Takes a minute or two.
    @MainActor
    func testQwenPreparesThenReadsWithoutStopping() async throws {
        guard ProcessInfo.processInfo.environment["LISTEN_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 to measure the real voice.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = ListenAudioPlayer { engine in
            engine.mainMixerNode.outputVolume = 0
            engine.prepare()
            try engine.start()
        }
        let model = ListenModel(
            store: SpokenSentenceStore(root: directory.appendingPathComponent("listen_audio", isDirectory: true)),
            defaults: InMemoryDefaults(),
            textFileURL: directory.appendingPathComponent("listen.txt"),
            player: player,
            mlxWork: MLXWorkGate()
        )
        model.text = Self.longerText
        model.speed = 4
        let sentences = ReadingDocument(text: Self.longerText).sentences.count

        let pressedPlay = ContinuousClock.now
        model.play()
        while !model.isReading, model.errorMessage == nil, ContinuousClock.now - pressedPlay < .seconds(600) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.errorMessage)
        let prepared = (ContinuousClock.now - pressedPlay).components.seconds
        model.play()
        var stops = 0
        var last = model.playback
        let started = ContinuousClock.now
        while model.playback != .stopped, model.errorMessage == nil, ContinuousClock.now - started < .seconds(300) {
            if last == .playing, model.playback == .waiting { stops += 1 }
            last = model.playback
            try await Task.sleep(for: .milliseconds(20))
        }
        print("BENCH prepare then read: \(sentences) sentences made in \(prepared)s (\(model.sentencesAtOnce) at once), read at 4x with \(stops) stops")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.playback, .stopped, "Didn't finish reading")
        XCTAssertEqual(stops, 0)
    }
}
