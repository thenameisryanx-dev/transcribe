import AudioCommon
import Foundation
import MLX
@testable import Qwen3TTSLocal
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

    /// Makes the same sentences the way speech-swift did (each text fed a token per frame, with "Speak naturally.") and
    /// the way Qwen's own code does (the whole sentence in the prompt, no instruction), eight at once so the shorter
    /// prompts are padded, and once more one at a time. Prints how fast each speaks and how often it pauses mid-sentence,
    /// and checks the new way's sentences end on their own, batched or not. With LISTEN_CLIPS set to a folder it also
    /// writes each way as a WAV to listen to, plus a paragraph made in one go.
    func testWholeSentencePromptsReadNaturally() async throws {
        guard ProcessInfo.processInfo.environment["LISTEN_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 to compare with the real voice.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let sentences = Array(ReadingDocument(text: Self.text).sentences.prefix(8)).map(\.spokenText)
        let model = try await Qwen3TTSModel.fromPretrained(
            modelId: SpeechModelFiles.ttsModelID,
            tokenizerModelId: SpeechModelFiles.ttsTokenizerID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsModelID),
            tokenizerCacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsTokenizerID)
        )
        _ = try model.synthesizeVoiceBatch(texts: Array(repeating: "Warming up.", count: 8), language: "english", speaker: "ryan")

        var start = Date()
        let before = try model.synthesizeVoiceBatch(
            texts: sentences, language: "english", speaker: "ryan", textFeed: .tokenPerStep, instruct: "Speak naturally.")
        let beforeTime = Date().timeIntervalSince(start)
        start = Date()
        let after = try model.synthesizeVoiceBatch(texts: sentences, language: "english", speaker: "ryan")
        let afterTime = Date().timeIntervalSince(start)
        let alone = try sentences.flatMap { try model.synthesizeVoiceBatch(texts: [$0], language: "english", speaker: "ryan") }
        func audioSeconds(_ audio: [[Float]]) -> Double { audio.reduce(0) { $0 + Double($1.count) / 24_000 } }
        print(String(format: "BENCH 8 at once: RTF %.2f before, %.2f with whole sentences",
                     beforeTime / audioSeconds(before), afterTime / audioSeconds(after)))

        func report(_ name: String, _ audio: [[Float]]) {
            var words = 0, pauses = 0, seconds = 0.0
            for (text, samples) in zip(sentences, audio) {
                words += text.split(separator: " ").count
                seconds += Double(samples.count) / 24_000
                // Pauses inside the sentence, not the quiet at either end.
                let length = Double(samples.count) / 24_000
                pauses += SpeechPauses.find(in: samples, sampleRate: 24_000)
                    .filter { $0.lowerBound > 0.2 && $0.upperBound < length - 0.2 }.count
            }
            print(String(format: "BENCH %@: %.1fs for %d words, %.2f words/s, %d pauses mid-sentence (%.2f per word)",
                         name, seconds, words, Double(words) / seconds, pauses, Double(pauses) / Double(words)))
        }
        report("token per step (before)", before)
        report("whole sentence, 8 at once", after)
        report("whole sentence, one at a time", alone)

        for (text, audio) in Array(zip(sentences, after)) + Array(zip(sentences, alone)) {
            let length = Double(audio.count) / 24_000
            let pace = Double(text.split(separator: " ").count) / length
            XCTAssertGreaterThan(pace, 1.4, "“\(text)” ran on (\(length)s)")
            XCTAssertLessThan(pace, 5, "“\(text)” was cut short (\(length)s)")
        }

        guard let folder = ProcessInfo.processInfo.environment["LISTEN_CLIPS"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Sentences joined with the short gap the reader leaves between them.
        func joined(_ audio: [[Float]]) -> [Float] {
            audio.flatMap { $0 + [Float](repeating: 0, count: 24_000 / 4) }
        }
        try WAVWriter.write(samples: joined(before), to: directory.appendingPathComponent("1-before.wav"))
        try WAVWriter.write(samples: joined(after), to: directory.appendingPathComponent("2-after.wav"))
        let paragraph = try model.synthesizeVoiceBatch(
            texts: [sentences.prefix(5).joined(separator: " ")], language: "english", speaker: "ryan")
        try WAVWriter.write(samples: paragraph[0], to: directory.appendingPathComponent("3-after-paragraph-in-one-go.wav"))
    }


    /// A sentence whose prompt is padded to sit beside a longer one scores its next frame as it does alone, after the
    /// prompt and a step later, about as closely as the unpadded sentence beside it does: the padding is masked out and
    /// its positions aren't moved. (Comparing the finished audio can't show this: even unpadded, a sentence made in a
    /// batch rounds a little differently from one made alone, and the speech goes its own way from there.)
    func testPaddedPromptsScoreAsTheyDoAlone() async throws {
        guard ProcessInfo.processInfo.environment["LISTEN_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 to check with the real voice.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let model = try await Qwen3TTSModel.fromPretrained(
            modelId: SpeechModelFiles.ttsModelID,
            tokenizerModelId: SpeechModelFiles.ttsTokenizerID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsModelID),
            tokenizerCacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsTokenizerID)
        )
        let tokenizer = try XCTUnwrap(model.tokenizer)
        let (speakerID, language) = model.resolveSpeaker("ryan", language: "english", languageExplicit: true)
        let codecPrefix = model.buildCodecPrefix(
            languageId: try XCTUnwrap(CodecTokens.languageId(for: language)), speakerTokenId: speakerID)
        // The first is the longest, so it isn't padded: it shows how closely any sentence in a batch matches.
        let texts = ["Water crosses by osmosis, moving toward the side with more dissolved particles.",
                     "Today we will see how these gradients store energy.", "It works."]
        let built = texts.map {
            model.buildWholeTextPrompt(
                textTokens: model.prepareTextTokens(text: $0, tokenizer: tokenizer),
                codecPrefixTokens: codecPrefix, instructTokens: nil)
        }
        let prompts = built.map(\.prompt)
        let ttsPad = built[0].ttsPadEmbed
        let length = prompts.map { $0.dim(1) }.max() ?? 0
        let (batchLogits, _, batchCache, padding) = model.prefillPadded(prompts)
        XCTAssertEqual(padding, [0] + padding.dropFirst())
        XCTAssertTrue(padding.dropFirst().allSatisfy { $0 > 0 })

        func lastScores(_ logits: MLXArray, row: Int) -> [Float] {
            logits[row, logits.dim(1) - 1, 0...].asType(.float32).asArray(Float.self)
        }
        func best(_ scores: [Float]) -> Int { scores.indices.max { scores[$0] < scores[$1] } ?? 0 }
        func difference(_ batched: [Float], _ alone: [Float]) -> Float {
            let span = (alone.max() ?? 0) - (alone.min() ?? 0)
            return (zip(batched, alone).map { abs($0 - $1) }.max() ?? 0) / max(span, 1e-6)
        }

        // Each sentence alone, and the frame it would start with: the next step is fed that, as making speech does.
        var aloneScores: [[Float]] = [], aloneStepScores: [[Float]] = [], firstFrames: [Int] = []
        for prompt in prompts {
            let (logits, _, cache) = model.talker(inputsEmbeds: prompt, offset: MLXArray(Int32(0)), cache: nil)
            let scores = lastScores(logits, row: 0)
            let frame = best(scores)
            let embed = ttsPad + model.talker.embedCodec(MLXArray([Int32(frame)]).reshaped(1, 1))
            let (stepLogits, _, _) = model.executeTalkerStep(embeds: embed, offset: prompt.dim(1), cache: cache)
            aloneScores.append(scores)
            aloneStepScores.append(lastScores(stepLogits, row: 0))
            firstFrames.append(frame)
        }
        let stepEmbeds = concatenated(firstFrames.map {
            ttsPad + model.talker.embedCodec(MLXArray([Int32($0)]).reshaped(1, 1))
        }, axis: 0)
        let (batchStep, _, _) = model.executeTalkerStepBatch(
            embeds: stepEmbeds, offset: length, cache: batchCache, padding: padding, shift: padding)

        for row in texts.indices {
            // What the step should give: the prompt and the step run as one prompt, with no cache.
            let embed = ttsPad + model.talker.embedCodec(MLXArray([Int32(firstFrames[row])]).reshaped(1, 1))
            let (truth, _, _) = model.talker(
                inputsEmbeds: concatenated([prompts[row], embed], axis: 1), offset: MLXArray(Int32(0)), cache: nil)
            let truthScores = lastScores(truth, row: 0)
            let batched = lastScores(batchLogits, row: row)
            let promptOff = difference(batched, aloneScores[row])
            let aloneOff = difference(aloneStepScores[row], truthScores)
            let batchedOff = difference(lastScores(batchStep, row: row), truthScores)
            print(String(format: "BENCH “%@” (padding %d): prompt off alone by %.1f%%; a step later, off the uncached "
                         + "result by %.1f%% alone and %.1f%% in the batch", texts[row], padding[row], promptOff * 100,
                         aloneOff * 100, batchedOff * 100))
            XCTAssertEqual(best(batched), best(aloneScores[row]), "“\(texts[row])”: a different first frame")
            XCTAssertLessThan(promptOff, 0.02, "“\(texts[row])” after its prompt")
            // A cached step rounds differently from the uncached one, by as much as 20% here even alone; in the batch it
            // should be no further off. Moved along by its padding instead, the shortest was 46% off its own alone.
            XCTAssertLessThan(batchedOff, aloneOff + 0.05, "“\(texts[row])” a step later")
        }
    }


    /// Reads the start of a real document as Listen does (24 at once, longest first, through `SentenceSpeaker`, so takes
    /// that come out wrong are made again) and flags sentences that still sound wrong, judged from the audio: a pace far
    /// from speech (babbling, or cut short), long silences inside, clipping or clicks. Prints each sentence's numbers and
    /// how fast it all was; with LISTEN_CLIPS set, writes the flagged ones to listen to. The document is LISTEN_TEXT (a
    /// text file; the lecture above by default), its first LISTEN_SENTENCES sentences (60), in the voice LISTEN_VOICE
    /// (aiden).
    func testFindsSentencesThatGlitch() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LISTEN_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 to check with the real voice.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let text = try environment["LISTEN_TEXT"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? Self.longerText
        let count = environment["LISTEN_SENTENCES"].flatMap(Int.init) ?? 60
        let voice = environment["LISTEN_VOICE"] ?? "aiden"
        let language = ListenLanguage.automatic.resolved(for: text)
        let sentences = Array(ReadingDocument(text: text).sentences.prefix(count))
        let texts = sentences.map { $0.voiceText(in: language) }
        let speaker = SentenceSpeaker(synthesizer: Qwen3Synthesizer(), aligner: Qwen3Aligner())
        try await speaker.synthesizer.load { _, _ in }
        try await speaker.aligner.load { _, _ in }
        _ = try await speaker.speak(Array(sentences.prefix(2)), voice: voice, language: language)

        let started = Date()
        var audio = [[Float]](repeating: [], count: texts.count)
        let order = texts.indices.sorted { sentences[$0].spokenText.count > sentences[$1].spokenText.count }
        for start in stride(from: 0, to: order.count, by: 24) {
            let batch = Array(order[start..<min(start + 24, order.count)])
            let made = try await speaker.speak(batch.map { sentences[$0] }, voice: voice, language: language)
            for (index, sentence) in zip(batch, made) { audio[index] = sentence.samples }
        }
        let seconds = Date().timeIntervalSince(started)
        let audioSeconds = audio.reduce(0) { $0 + Double($1.count) / 24_000 }
        print(String(format: "BENCH %d sentences, %.1fs of audio in %.1fs: RTF %.2f, making and timing words",
                     texts.count, audioSeconds, seconds, seconds / audioSeconds))

        let directory = environment["LISTEN_CLIPS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var flaggedCount = 0
        for (index, samples) in audio.enumerated() {
            let seconds = Double(samples.count) / 24_000
            let words = max(texts[index].split(whereSeparator: \.isWhitespace).count, 1)
            let pace = Double(words) / max(seconds, 0.01)
            let peak = samples.map(abs).max() ?? 0
            let clipped = samples.filter { abs($0) > 0.98 }.count
            let longestPause = SpeechPauses.find(in: samples, sampleRate: 24_000)
                .filter { $0.lowerBound > 0.2 && $0.upperBound < seconds - 0.2 }
                .map { $0.upperBound - $0.lowerBound }.max() ?? 0
            let clicks = SpeechCheck.clicks(in: samples)
            var problems: [String] = []
            if pace < 1.3 { problems.append("slow (babbling?)") }
            if pace > 4.5 { problems.append("fast (cut short?)") }
            if longestPause > 1.0 { problems.append(String(format: "%.1fs pause", longestPause)) }
            if clipped > 0 { problems.append("\(clipped) clipped") }
            if clicks > SpeechCheck.allowedClicks { problems.append("\(clicks) clicks") }
            print(String(format: "BENCH %3d %5.1fs %2d words %.1f w/s%@  “%@”", index, seconds, words, pace,
                         problems.isEmpty ? "" : "  ⚠ " + problems.joined(separator: ", "), texts[index]))
            if !problems.isEmpty, let directory {
                flaggedCount += 1
                try WAVWriter.write(samples: samples, to: directory.appendingPathComponent(String(format: "sentence-%03d.wav", index)))
            }
        }
        print("BENCH \(flaggedCount) of \(audio.count) sentences flagged")
        if let directory {
            try WAVWriter.write(samples: audio.flatMap { $0 + [Float](repeating: 0, count: 6_000) },
                                to: directory.appendingPathComponent("all.wav"))
        }
    }


    /// Decoding keeps every sample: a frame of codes is 1920 samples, the last frame's included, and a sentence comes
    /// out as it does decoded in one pass. speech-swift decoded 2-second pieces that each came out short, losing
    /// about 0.1 s of speech at every seam. Longer than 300 frames, it's decoded in pieces after 25 frames of context, as
    /// Qwen's code does, still without losing any.
    func testDecodingKeepsEverySample() async throws {
        guard ProcessInfo.processInfo.environment["LISTEN_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LISTEN_BENCHMARK=1 to check with the real voice.")
        }
        try XCTSkipUnless(SpeechModelFiles.isDownloaded(), "The Qwen3-TTS models aren't downloaded.")
        let model = try await Qwen3TTSModel.fromPretrained(
            modelId: SpeechModelFiles.ttsModelID,
            tokenizerModelId: SpeechModelFiles.ttsTokenizerID,
            cacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsModelID),
            tokenizerCacheDir: try SpeechModelFiles.directory(for: SpeechModelFiles.ttsTokenizerID)
        )
        let text = "The storm creates a moment where a title like king means nothing, which is exactly the question the whole play raises about his power on the island."
        let codes = try XCTUnwrap(try model.makeVoiceBatchCodes(texts: [text], language: "english", speaker: "aiden")[0])
        let decoder = model.codecDecoder
        let frames = codes.dim(2)
        XCTAssertGreaterThan(frames, 50, "Too short to have had 2-second seams")

        let decoded = decoder.decode(codes: codes)
        XCTAssertEqual(decoded.count, frames * 1920)
        let padding = MLXArray.zeros([1, 16, 10]).asType(codes.dtype)
        let onePass = decoder.callAsFunction(concatenated([codes, padding], axis: 2)).squeezed().asArray(Float.self)
        let difference = zip(decoded, onePass).map { abs($0 - $1) }.max() ?? 1
        print(String(format: "BENCH %d frames: %d samples, off one pass by %.6f", frames, decoded.count, difference))
        XCTAssertLessThan(difference, 1e-3)

        // Long enough for pieces: the same codes four times over.
        let long = concatenated([codes, codes, codes, codes], axis: 2)
        let longDecoded = decoder.decode(codes: long)
        XCTAssertEqual(longDecoded.count, long.dim(2) * 1920)
        let longOnePass = decoder.callAsFunction(concatenated([long, padding], axis: 2)).squeezed().asArray(Float.self)
        let seam = 300 * 1920
        func rms(_ values: [Float]) -> Float { (values.map { $0 * $0 }.reduce(0, +) / Float(max(values.count, 1))).squareRoot() }
        let nearSeam = zip(longDecoded[(seam - 4800)..<(seam + 4800)], longOnePass[(seam - 4800)..<(seam + 4800)]).map { $0 - $1 }
        print(String(format: "BENCH %d frames in pieces: off one pass by rms %.4f around the seam (speech rms %.4f)",
                     long.dim(2), rms(nearSeam), rms(Array(longOnePass[(seam - 4800)..<(seam + 4800)]))))
    }

}
