import Foundation
import Qwen3TTS
import XCTest

@testable import LectureTranscribeNative

/// Measures how fast the real Qwen3-TTS voice makes speech on this Mac, as a real-time factor (seconds to make ÷
/// seconds of audio; below 1 keeps ahead of playback at 1×), the way the reader makes it: one sentence, then its word
/// timing. On a base M4 it's about 1.3, so the reader falls behind. Needs the Qwen3-TTS models downloaded, so it runs
/// only when asked:
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
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(for: .qwen), "The Qwen3-TTS models aren't downloaded.")
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

        // One at a time, as the reader does today: make a sentence, then time its words.
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

    /// Reads a document with the real Qwen3-TTS voice through the real (muted) player, from a fresh start, and
    /// counts how often reading stopped to wait for the voice after its head start. Takes a few minutes.
    @MainActor
    func testQwenReadsWithoutStoppingAfterItsHeadStart() async throws {
        guard ProcessInfo.processInfo.environment["LISTEN_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 to measure the real voice.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(for: .qwen), "The Qwen3-TTS models aren't downloaded.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = ListenAudioPlayer { engine in
            engine.mainMixerNode.outputVolume = 0
            engine.prepare()
            try engine.start()
        }
        let model = ListenModel(
            synthesizers: [.kokoro: KokoroSynthesizer(), .qwen: Qwen3Synthesizer()],
            aligner: Qwen3Aligner(),
            store: SpokenSentenceStore(root: directory.appendingPathComponent("listen_audio", isDirectory: true)),
            defaults: UserDefaults(suiteName: "ListenBenchmark.\(UUID().uuidString)")!,
            textFileURL: directory.appendingPathComponent("listen.txt"),
            player: player,
            mlxWork: MLXWorkGate()
        )
        model.engine = .qwen
        model.text = Self.longerText
        let sentences = ReadingDocument(text: Self.longerText).sentences.count
        try await model.loadVoice()

        let pressedPlay = ContinuousClock.now
        model.play()
        var firstEstimate: TimeInterval?
        var started: ContinuousClock.Instant?
        var stops = 0
        var last = model.playback
        while model.playback != .stopped, ContinuousClock.now - pressedPlay < .seconds(600) {
            if firstEstimate == nil, let wait = model.headStartWait { firstEstimate = wait }
            if model.playback == .playing, started == nil { started = .now }
            if started != nil, last == .playing, model.playback == .waiting { stops += 1 }
            if model.errorMessage != nil { break }
            last = model.playback
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(model.errorMessage)
        let waited = started.map { ($0 - pressedPlay).components.seconds } ?? -1
        let total = (ContinuousClock.now - pressedPlay).components.seconds
        print("BENCH head start: \(sentences) sentences, first estimate \(Int(firstEstimate ?? 0))s, waited \(waited)s, stopped \(stops) times after starting, done in \(total)s")
        XCTAssertEqual(model.playback, .stopped, "Didn't finish reading")
        XCTAssertEqual(stops, 0)
    }

    /// Reads the benchmark text with the real Kokoro voice and checks what was wrong with it before: sentences made
    /// in pieces stopped for most of a second where the pieces met, and the aligner's word times were a quarter of a
    /// second off on average. Kokoro now times its own words, so no word starts in a pause.
    func testKokoroReadsWithoutLongPausesAndTimesItsOwnWords() async throws {
        guard ProcessInfo.processInfo.environment["LISTEN_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 to check the real voice.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(for: .kokoro), "The Kokoro model isn't downloaded.")
        let voice = KokoroSynthesizer()
        try await voice.load { _, _ in }
        for sentence in ReadingDocument(text: Self.text).sentences {
            let speech = try await voice.synthesize(sentence.spokenText, voice: ListenEngine.kokoro.defaultVoiceID, language: .english)
            let times = try XCTUnwrap(speech.wordTimes, "Kokoro didn't time its words")
            XCTAssertEqual(times.count, sentence.spokenText.split(separator: " ").count)
            let duration = Double(speech.samples.count) / Double(speech.sampleRate)
            let pauses = SpeechPauses.find(in: speech.samples, sampleRate: speech.sampleRate)
            for pause in pauses where pause.lowerBound > 0.05 && pause.upperBound < duration - 0.05 {
                XCTAssertLessThanOrEqual(pause.upperBound - pause.lowerBound, KokoroPieces.longestPause + 0.05, "A long pause in “\(sentence.spokenText)”")
            }
            for word in times {
                XCTAssertFalse(pauses.contains { $0.lowerBound + 0.03 < word.start && word.start < $0.upperBound - 0.03 }, "“\(word.text)” starts in a pause")
            }
            print(String(format: "BENCH kokoro: %.2fs, %d words, %d pauses", duration, times.count, pauses.count))
        }
    }
}
