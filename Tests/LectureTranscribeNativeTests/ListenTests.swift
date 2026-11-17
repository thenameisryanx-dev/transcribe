import Foundation
import XCTest

@testable import LectureTranscribeNative

// MARK: - Fakes

/// A voice that "speaks" each sentence as a short burst of silence and records what it was asked to say and how
/// many at a time, so the reader can be tested without downloading or running the real models. Each word lasts
/// `secondsPerWord`, and each batch takes `secondsToMake` (cut short when the task is cancelled).
final class FakeSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    let identifier: String
    let secondsPerWord: Double
    let secondsToMake: Double
    var failure: Error?
    static let sampleRate = 1_000
    private let lock = NSLock()
    private var said: [String] = []
    private var batches: [Int] = []
    private var loaded = false

    init(identifier: String = "fake-voice", secondsPerWord: Double = 0.1, secondsToMake: Double = 0) {
        self.identifier = identifier
        self.secondsPerWord = secondsPerWord
        self.secondsToMake = secondsToMake
    }

    var spoken: [String] { lock.withLock { said } }
    var batchSizes: [Int] { lock.withLock { batches } }
    var isLoaded: Bool { lock.withLock { loaded } }

    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        progress(1, "Loaded")
        lock.withLock { loaded = true }
    }

    func synthesize(_ texts: [String], voice: String, language: ListenLanguage) async throws -> [SynthesizedSpeech] {
        if secondsToMake > 0 { try await Task.sleep(for: .seconds(secondsToMake)) }
        if let failure { throw failure }
        lock.withLock {
            said.append(contentsOf: texts)
            batches.append(texts.count)
        }
        return texts.map { text in
            let words = text.split(separator: " ").count
            return SynthesizedSpeech(
                samples: [Float](repeating: 0, count: Int(Double(max(words, 1) * Self.sampleRate) * secondsPerWord)),
                sampleRate: Self.sampleRate
            )
        }
    }

    func unload() {
        lock.withLock { loaded = false }
    }
}

/// Times each word a tenth of a second after the one before, as the fake voice speaks them.
final class FakeAligner: WordAligner, @unchecked Sendable {
    let identifier = "fake-aligner"
    var isLoaded = true

    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {}

    func align(samples: [Float], sampleRate: Int, text: String, language: ListenLanguage) async throws -> [AlignedWordTime] {
        text.split(separator: " ").enumerated().map { index, word in
            AlignedWordTime(text: String(word), start: Double(index) * 0.1, end: Double(index) * 0.1 + 0.08)
        }
    }

    func unload() {}
}

/// A Listen model with a fake voice, making `sentencesAtOnce` sentences at a time, with its own saved text, settings
/// and saved speech in `directory`. By default its audio device fails at once, so tests don't use this Mac's speakers.
@MainActor
func makeTestListenModel(
    directory: URL,
    synthesizer: FakeSynthesizer = FakeSynthesizer(),
    sentencesAtOnce: Int = 2,
    player: ListenAudioPlayer? = nil,
    mlxWork: MLXWorkGate = MLXWorkGate(),
    defaults: UserDefaults = UserDefaults(suiteName: "ListenTests.\(UUID().uuidString)")!
) -> ListenModel {
    let model = ListenModel(
        synthesizer: synthesizer,
        aligner: FakeAligner(),
        store: SpokenSentenceStore(root: directory.appendingPathComponent("listen_audio", isDirectory: true)),
        defaults: defaults,
        textFileURL: directory.appendingPathComponent("listen.txt"),
        player: player ?? makeSlowDevicePlayer(delay: 0),
        mlxWork: mlxWork
    )
    model.sentencesAtOnce = sentencesAtOnce
    return model
}

/// An audio device that takes `delay` to wake and then can't be used, so tests don't depend on this Mac's speakers.
struct SlowDeviceError: LocalizedError {
    var errorDescription: String? { "The device didn't start." }
}

@MainActor
func makeSlowDevicePlayer(delay: TimeInterval) -> ListenAudioPlayer {
    ListenAudioPlayer { _ in
        Thread.sleep(forTimeInterval: delay)
        throw SlowDeviceError()
    }
}

// MARK: - Splitting text

final class ReadingDocumentTests: XCTestCase {
    private func words(_ document: ReadingDocument, _ sentence: Int) -> [String] {
        document.sentences[sentence].words.map(\.text)
    }

    private func substring(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    func testSplitsSentencesAndTrimsPunctuationFromWords() {
        let text = "Hello, world! This is “Listen.” Isn't it (really) nice?"
        let document = ReadingDocument(text: text)
        XCTAssertEqual(document.sentences.count, 3)
        XCTAssertEqual(words(document, 0), ["Hello", "world"])
        XCTAssertEqual(words(document, 1), ["This", "is", "Listen"])
        XCTAssertEqual(words(document, 2), ["Isn't", "it", "really", "nice"])
        // Ranges point at exactly the word in the text, which is what gets highlighted.
        for sentence in document.sentences {
            for word in sentence.words {
                XCTAssertEqual(substring(text, word.range), word.text)
            }
        }
        XCTAssertEqual(substring(text, document.sentences[0].range), "Hello, world!")
    }

    func testHeadingsAndListItemsAreTheirOwnSentences() {
        let text = "# Chapter One\nIt was a dark night.\n- First point\n- Second point"
        let document = ReadingDocument(text: text)
        XCTAssertEqual(document.sentences.map(\.spokenText), ["Chapter One", "It was a dark night.", "- First point", "- Second point"])
        XCTAssertEqual(words(document, 2), ["First", "point"])
    }

    func testLinesWrappedMidSentenceAreJoined() {
        let text = "This sentence was wrapped\nby an email program. Next one.\nHeading\nA capitalised line stays apart."
        let document = ReadingDocument(text: text)
        XCTAssertEqual(document.sentences.map { words(document, document.sentences.firstIndex(of: $0)!).joined(separator: " ") }, [
            "This sentence was wrapped by an email program",
            "Next one",
            "Heading",
            "A capitalised line stays apart",
        ])
    }

    func testVeryLongSentencesAreSplitAtAPause() {
        let clause = "and the reading went on and on without a full stop in sight"
        let text = Array(repeating: clause, count: 12).joined(separator: ", ") + "."
        let document = ReadingDocument(text: text)
        XCTAssertGreaterThan(document.sentences.count, 1)
        for sentence in document.sentences {
            XCTAssertLessThanOrEqual(sentence.range.length, ReadingDocument.maxSentenceLength)
        }
        // Nothing is lost or read twice.
        XCTAssertEqual(document.wordCount, 12 * clause.split(separator: " ").count)
    }

    func testChineseIsSplitIntoWords() {
        let document = ReadingDocument(text: "我喜欢读书。")
        XCTAssertEqual(document.sentences.count, 1)
        XCTAssertGreaterThan(document.sentences[0].words.count, 1)
    }

    func testTextWithNothingToSayHasNoSentences() {
        XCTAssertTrue(ReadingDocument(text: "  \n*** \n — \n").isEmpty)
        XCTAssertTrue(ReadingDocument(text: "").isEmpty)
    }

    func testSpokenTextDropsFormattingMarks() {
        let document = ReadingDocument(text: "## **Bold** idea")
        XCTAssertEqual(document.sentences[0].spokenText, "Bold idea")
    }

    func testClickFindsTheWordUnderIt() {
        let text = "One two. Three four."
        let document = ReadingDocument(text: text)
        let three = (text as NSString).range(of: "Three")
        XCTAssertEqual(document.position(at: three.location + 2), ReadingPosition(sentence: 1, word: 0))
        XCTAssertEqual(document.position(at: 0), ReadingPosition(sentence: 0, word: 0))
        // Between words: the next word.
        XCTAssertEqual(document.position(at: (text as NSString).range(of: " four").location), ReadingPosition(sentence: 1, word: 1))
        XCTAssertNil(document.position(at: (text as NSString).length))
    }
}

// MARK: - Word timing

final class WordTimingMatcherTests: XCTestCase {
    private func aligned(_ items: [(String, Double, Double)]) -> [AlignedWordTime] {
        items.map { AlignedWordTime(text: $0.0, start: $0.1, end: $0.2) }
    }

    func testMatchingWordsGetTheAlignersTimes() {
        let times = WordTimingMatcher.timings(
            for: ["Hello", "world"],
            aligned: aligned([("hello", 0.1, 0.4), ("world", 0.5, 0.9)]),
            duration: 1
        )
        XCTAssertEqual(times, [WordTime(start: 0.1, end: 0.4), WordTime(start: 0.5, end: 0.9)])
    }

    func testAWordTheAlignerSkippedIsPlacedBetweenItsNeighbours() {
        let times = WordTimingMatcher.timings(
            for: ["one", "two", "three"],
            aligned: aligned([("one", 0, 0.2), ("three", 0.6, 0.8)]),
            duration: 1
        )
        XCTAssertEqual(times[1].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(times[1].end, 0.6, accuracy: 1e-9)
        XCTAssertEqual(times[2], WordTime(start: 0.6, end: 0.8))
    }

    func testAnExtraAlignedWordIsSkipped() {
        let times = WordTimingMatcher.timings(
            for: ["one", "three"],
            aligned: aligned([("one", 0, 0.2), ("two", 0.3, 0.4), ("three", 0.6, 0.8)]),
            duration: 1
        )
        XCTAssertEqual(times, [WordTime(start: 0, end: 0.2), WordTime(start: 0.6, end: 0.8)])
    }

    func testAWordSplitInTwoByTheAlignerSpansBothParts() {
        let times = WordTimingMatcher.timings(
            for: ["a", "well-known", "fact"],
            aligned: aligned([("a", 0, 0.1), ("well", 0.2, 0.4), ("known", 0.4, 0.7), ("fact", 0.8, 1.0)]),
            duration: 1.2
        )
        XCTAssertEqual(times[1], WordTime(start: 0.2, end: 0.7))
        XCTAssertEqual(times[2], WordTime(start: 0.8, end: 1.0))
    }

    func testTwoWordsTheAlignerJoinedShareItsTime() {
        let times = WordTimingMatcher.timings(
            for: ["New", "York", "rocks"],
            aligned: aligned([("newyork", 0, 0.8), ("rocks", 1.0, 1.4)]),
            duration: 1.5
        )
        XCTAssertEqual(times[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(times[1].end, 0.8, accuracy: 1e-9)
        XCTAssertLessThan(times[0].end, times[1].end)
        XCTAssertEqual(times[2], WordTime(start: 1.0, end: 1.4))
    }

    func testWithoutAlignmentWordsAreSpreadByLength() {
        let times = WordTimingMatcher.timings(for: ["a", "bbb"], aligned: [], duration: 4)
        XCTAssertEqual(times[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(times[0].end, 1, accuracy: 1e-9)
        XCTAssertEqual(times[1].end, 4, accuracy: 1e-9)
    }

    func testTimesOnlyMoveForwardAndStayInsideTheAudio() {
        let times = WordTimingMatcher.timings(
            for: ["one", "two", "three"],
            aligned: aligned([("one", 0.5, 0.6), ("two", 0.2, 0.3), ("three", 3, 4)]),
            duration: 2
        )
        XCTAssertEqual(times.map(\.start), times.map(\.start).sorted())
        XCTAssertTrue(times.allSatisfy { $0.end <= 2 && $0.start <= $0.end })
    }

    func testTheWordBeingSpokenIsTheLastOneThatStarted() {
        let times = [WordTime(start: 0.2, end: 0.4), WordTime(start: 0.5, end: 0.7), WordTime(start: 0.9, end: 1.1)]
        XCTAssertEqual(WordTimingMatcher.wordIndex(at: 0, in: times), 0)
        XCTAssertEqual(WordTimingMatcher.wordIndex(at: 0.45, in: times), 0)
        XCTAssertEqual(WordTimingMatcher.wordIndex(at: 0.5, in: times), 1)
        XCTAssertEqual(WordTimingMatcher.wordIndex(at: 5, in: times), 2)
        XCTAssertNil(WordTimingMatcher.wordIndex(at: 1, in: []))
    }
}

// MARK: - Saved speech

final class SpokenSentenceStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSavedSentencesComeBackTheSame() {
        let store = SpokenSentenceStore(root: root)
        let sentence = SpokenSentence(samples: [0, 0.5, -0.25, 1], sampleRate: 24_000, wordTimes: [WordTime(start: 0, end: 0.1)])
        let key = SpokenSentenceStore.key(text: "Hi.", engine: "e", voice: "ryan", language: "english")
        XCTAssertNil(store.load(key))
        store.save(sentence, key: key)
        XCTAssertEqual(store.load(key), sentence)
        XCTAssertGreaterThan(store.size(), 0)
        store.removeAll()
        XCTAssertNil(store.load(key))
    }

    func testEverythingThatChangesTheSoundChangesTheKey() {
        let base = SpokenSentenceStore.key(text: "Hi.", engine: "e", voice: "ryan", language: "english")
        XCTAssertNotEqual(base, SpokenSentenceStore.key(text: "Hi!", engine: "e", voice: "ryan", language: "english"))
        XCTAssertNotEqual(base, SpokenSentenceStore.key(text: "Hi.", engine: "f", voice: "ryan", language: "english"))
        XCTAssertNotEqual(base, SpokenSentenceStore.key(text: "Hi.", engine: "e", voice: "aiden", language: "english"))
        XCTAssertNotEqual(base, SpokenSentenceStore.key(text: "Hi.", engine: "e", voice: "ryan", language: "french"))
    }

    func testOldSentencesArePruned() throws {
        let store = SpokenSentenceStore(root: root)
        let key = SpokenSentenceStore.key(text: "Old.", engine: "e", voice: "v", language: "l")
        store.save(SpokenSentence(samples: [0], sampleRate: 1, wordTimes: []), key: key)
        let old = Date().addingTimeInterval(-SpokenSentenceStore.maxAge - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent("\(key).json").path)
        store.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(key).f32").path))
    }
}

// MARK: - Opening files

final class ListenDocumentImporterTests: XCTestCase {
    func testPDFLineBreaksAreJoinedButParagraphsKept() {
        let text = "This line was broken\nby the page, and a hyph-\nenated word too.\n\nNew paragraph."
        XCTAssertEqual(
            ListenDocumentImporter.unwrapLines(text),
            "This line was broken by the page, and a hyphenated word too.\n\nNew paragraph."
        )
    }

    func testReadsTextAndHTMLFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plain = directory.appendingPathComponent("notes.txt")
        try "Plain notes.".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ListenDocumentImporter.text(from: plain), "Plain notes.")

        let html = directory.appendingPathComponent("page.html")
        try "<html><body><h1>Title</h1><p>Some <b>bold</b> text.</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let read = try ListenDocumentImporter.text(from: html)
        XCTAssertTrue(read.contains("Title"))
        XCTAssertTrue(read.contains("Some bold text."))
    }
}

// MARK: - Reading

@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

// MARK: - Quitting while speaking

/// Quitting used to crash when a sentence was being spoken: `exit()` destroyed MLX's compile cache while the MLX
/// queue was still using it. The app now waits for that work before it quits.
final class MLXWorkGateTests: XCTestCase {
    func testClosingWhenIdleIsReadyAtOnceAndRefusesNewWork() {
        let gate = MLXWorkGate()
        XCTAssertEqual(try gate.run { 1 }, 1)
        XCTAssertTrue(gate.close { XCTFail("Nothing was running") })
        XCTAssertThrowsError(try gate.run { XCTFail("Ran after the gate closed") }) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testClosingWaitsForTheWorkRunning() {
        let gate = MLXWorkGate()
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let finished = Locked(false)
        DispatchQueue.global().async {
            try? gate.run {
                started.signal()
                finish.wait()
                finished.value = true
            }
        }
        started.wait()

        let idle = expectation(description: "idle")
        XCTAssertFalse(gate.close {
            XCTAssertTrue(finished.value, "Called before the work finished")
            idle.fulfill()
        })
        finish.signal()
        wait(for: [idle], timeout: 5)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class QuitTests: XCTestCase {
    @MainActor
    func testQuitIsImmediateWhenNothingIsSpeaking() {
        let delegate = AppLifecycleDelegate()
        // So a window another test closes can't make it quit the test run.
        delegate.shouldTerminateAfterLastWindowClosed = { false }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        delegate.prepareToTerminate = { _ in true }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    @MainActor
    func testStoppingForQuitStopsReadingAndClosesTheGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let synthesizer = FakeSynthesizer()
        let gate = MLXWorkGate()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, mlxWork: gate)
        model.text = (1...20).map { "Sentence number \($0) is here." }.joined(separator: " ")
        model.play()
        await waitUntil { !synthesizer.spoken.isEmpty }
        XCTAssertFalse(synthesizer.spoken.isEmpty)

        XCTAssertTrue(model.stopForQuit { XCTFail("Nothing was running in the gate") })
        let spokenAtQuit = synthesizer.spoken.count
        try? await Task.sleep(for: .milliseconds(200))
        // Making the speech stopped (a batch already being made may finish), and no more MLX work can start.
        XCTAssertLessThanOrEqual(synthesizer.spoken.count, spokenAtQuit + model.sentencesAtOnce)
        XCTAssertThrowsError(try gate.run {})
    }
}

final class ListenModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }


    private func sentences(_ count: Int) -> String {
        (1...count).map { "Sentence number \($0) is here." }.joined(separator: " ")
    }

    @MainActor
    func testPlayMakesEverySentenceInBatchesThenOpensTheReader() async {
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, sentencesAtOnce: 3)
        model.text = sentences(7)
        model.play()
        XCTAssertEqual(model.stage, .preparing)
        XCTAssertFalse(model.isReading)
        XCTAssertNil(model.currentWordRange, "Nothing is highlighted before the reader opens")

        await waitUntil { model.isReading }
        XCTAssertEqual(model.stage, .reading)
        // What the voice is given, numbers written out.
        XCTAssertEqual(Set(synthesizer.spoken), Set(ReadingDocument(text: sentences(7)).sentences.map { $0.voiceText(in: .english) }))
        XCTAssertTrue(synthesizer.spoken.contains("Sentence number seven is here."))
        XCTAssertEqual(synthesizer.batchSizes, [3, 3, 1])
        // After a wait the reader opens ready, at the top, without starting to talk by itself.
        XCTAssertEqual(model.position, ReadingPosition(sentence: 0, word: 0))
        XCTAssertEqual(model.playback, .paused)
        XCTAssertNil(model.preparation)
        model.editText()
    }

    @MainActor
    func testProgressCountsTheSentencesMade() async {
        let synthesizer = FakeSynthesizer(secondsToMake: 0.3)
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, sentencesAtOnce: 2)
        model.text = sentences(6)
        model.play()
        await waitUntil { (model.preparation?.done ?? 0) >= 2 }
        XCTAssertEqual(model.preparation?.done, 2)
        XCTAssertEqual(model.preparation?.total, 6)
        XCTAssertEqual(model.preparation?.fraction ?? 0, 1.0 / 3, accuracy: 0.001)
        XCTAssertNotNil(model.preparation?.secondsLeft)
        XCTAssertTrue(model.isPreparing)
        model.cancelPreparing()
    }

    @MainActor
    func testCancelGoesBackToTheTextAndKeepsWhatWasMade() async {
        let synthesizer = FakeSynthesizer(secondsToMake: 0.3)
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, sentencesAtOnce: 2)
        model.text = sentences(6)
        model.play()
        await waitUntil { (model.preparation?.done ?? 0) == 2 }
        model.cancelPreparing()
        XCTAssertEqual(model.stage, .editing)
        XCTAssertNil(model.document)
        XCTAssertNil(model.preparation)
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(synthesizer.spoken.count, 2, "The batch being made stops")

        // Playing again makes only what's left.
        model.play()
        await waitUntil({ model.isReading }, timeout: 10)
        XCTAssertEqual(synthesizer.spoken.count, 6)
        XCTAssertEqual(Set(synthesizer.spoken).count, 6)
        model.editText()
    }

    @MainActor
    func testADocumentAlreadyMadeIsReadAtOnce() async {
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, player: makeSlowDevicePlayer(delay: 1))
        model.text = sentences(3)
        model.play()
        await waitUntil { model.isReading }
        model.editText()

        model.play()
        await waitUntil { model.isReading }
        XCTAssertEqual(synthesizer.spoken.count, 3, "Nothing is made twice")
        // Nothing had to be made, so reading starts by itself, waiting for the audio device.
        await waitUntil { model.playback == .waiting }
        XCTAssertEqual(model.playback, .waiting)
        await waitUntil({ model.errorMessage != nil }, timeout: 3)
        XCTAssertEqual(model.errorMessage, "Couldn't play the audio: The device didn't start.")
        XCTAssertEqual(model.playback, .paused)
        model.editText()
    }

    @MainActor
    func testPausingWhileTheAudioDeviceStartsStaysPaused() async {
        let model = makeTestListenModel(directory: directory, player: makeSlowDevicePlayer(delay: 0.5))
        model.text = "One sentence. And another."
        model.play()
        await waitUntil { model.isReading }
        model.play()
        await waitUntil { model.playback == .waiting }
        model.pause()
        XCTAssertEqual(model.playback, .paused)

        // The device finishing its start doesn't play the sentence (or report on it) after the pause.
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.playback, .paused)
        XCTAssertNil(model.errorMessage)
        model.editText()
    }

    @MainActor
    func testJumpingToAWordMovesThere() async {
        let model = makeTestListenModel(directory: directory)
        model.text = (1...10).map { "Line \($0) goes here." }.joined(separator: " ")
        model.play()
        await waitUntil { model.isReading }

        let target = (model.text as NSString).range(of: "Line 9")
        model.jump(toLocation: target.location + 5)
        XCTAssertEqual(model.position, ReadingPosition(sentence: 8, word: 1))
        XCTAssertEqual(model.currentWordRange.map { (model.text as NSString).substring(with: $0) }, "9")
        model.editText()
    }

    @MainActor
    func testReadingPicksUpWhereItStopped() async {
        let model = makeTestListenModel(directory: directory)
        model.text = "First. Second. Third. Fourth."
        model.play()
        await waitUntil { model.isReading }
        model.jump(to: ReadingPosition(sentence: 2, word: 0))
        model.editText()
        XCTAssertFalse(model.isReading)

        model.play()
        await waitUntil { model.isReading }
        XCTAssertEqual(model.position?.sentence, 2)
        model.editText()
    }

    @MainActor
    func testTextIsKeptBetweenLaunches() async {
        let model = makeTestListenModel(directory: directory)
        model.text = "Remember me."
        let file = directory.appendingPathComponent("listen.txt")
        await waitUntil { (try? String(contentsOf: file, encoding: .utf8)) == "Remember me." }
        XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), "Remember me.")
    }

    @MainActor
    func testChangingTheVoiceWhileReadingMakesTheSpeechAgainAndKeepsThePlace() async {
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer)
        model.text = sentences(4)
        model.play()
        await waitUntil { model.isReading }
        model.jump(to: ReadingPosition(sentence: 2, word: 0))

        model.voiceID = "aiden"
        XCTAssertEqual(model.stage, .preparing)
        await waitUntil { model.isReading }
        XCTAssertEqual(synthesizer.spoken.count, 8, "Every sentence is made again in the new voice")
        XCTAssertEqual(model.position, ReadingPosition(sentence: 2, word: 0))
        model.editText()
    }

    @MainActor
    func testNumbersAreWrittenOutForTheVoice() async {
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer)
        model.language = .english
        model.text = "In 1990 a ticket cost $5."
        model.play()
        await waitUntil { model.isReading }
        XCTAssertEqual(synthesizer.spoken, ["In nineteen ninety a ticket cost five dollars."])
        model.editText()
    }

    @MainActor
    func testAVoiceThatFailsSaysSoAndGoesBackToTheText() async {
        let synthesizer = FakeSynthesizer()
        synthesizer.failure = SlowDeviceError()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer)
        model.text = sentences(2)
        model.play()
        await waitUntil { model.errorMessage != nil }
        XCTAssertEqual(model.errorMessage, "Couldn't make the speech: The device didn't start.")
        XCTAssertEqual(model.stage, .editing)
    }

    func testSentencesAtOnceDependsOnTheMacsGPUAndMemory() {
        let gigabyte: UInt64 = 1_073_741_824
        // A base M4 with 16 GB: 24, where making more at once stopped getting faster.
        XCTAssertEqual(ListenVoiceModel.defaultSentencesAtOnce(physicalMemory: 16 * gigabyte, gpuCores: 10), 24)
        XCTAssertEqual(ListenVoiceModel.defaultSentencesAtOnce(physicalMemory: 64 * gigabyte, gpuCores: 40), 24)
        // A GPU with fewer cores fills sooner.
        XCTAssertEqual(ListenVoiceModel.defaultSentencesAtOnce(physicalMemory: 16 * gigabyte, gpuCores: 8), 16)
        // Little memory beside the model wins over a big GPU.
        XCTAssertEqual(ListenVoiceModel.defaultSentencesAtOnce(physicalMemory: 8 * gigabyte, gpuCores: 10), 4)
        XCTAssertEqual(ListenVoiceModel.defaultSentencesAtOnce(physicalMemory: 4 * gigabyte, gpuCores: 10), 2)
        // When the GPU's size can't be read, a safe middle.
        XCTAssertEqual(ListenVoiceModel.defaultSentencesAtOnce(physicalMemory: 16 * gigabyte, gpuCores: nil), 8)
        XCTAssertTrue(ListenVoiceModel.sentencesAtOnceChoices.contains(ListenVoiceModel.defaultSentencesAtOnce()))
        XCTAssertNotNil(ListenVoiceModel.voice(ListenVoiceModel.defaultVoiceID))
    }

    @MainActor
    func testAutomaticLanguageFollowsTheText() {
        XCTAssertEqual(ListenLanguage.automatic.resolved(for: "Bonjour tout le monde, comment allez-vous aujourd'hui ?"), .french)
        XCTAssertEqual(ListenLanguage.automatic.resolved(for: "The quick brown fox jumps over the lazy dog."), .english)
        XCTAssertEqual(ListenLanguage.german.resolved(for: "The quick brown fox."), .german)
    }
}

// MARK: - Pauses

final class SpeechPausesTests: XCTestCase {
    /// Half a second of sound, `gap` seconds of silence, then half a second of sound, at 1 kHz.
    private func audio(gap: Double) -> [Float] {
        let tone = (0..<500).map { Float(sin(Double($0) * 0.5)) * 0.5 }
        return tone + [Float](repeating: 0, count: Int(gap * 1_000)) + tone
    }

    func testFindsAPauseButNotAShortGap() {
        let pauses = SpeechPauses.find(in: audio(gap: 0.4), sampleRate: 1_000)
        XCTAssertEqual(pauses.count, 1)
        XCTAssertEqual(pauses[0].lowerBound, 0.5, accuracy: 0.02)
        XCTAssertEqual(pauses[0].upperBound, 0.9, accuracy: 0.02)
        XCTAssertTrue(SpeechPauses.find(in: audio(gap: 0.08), sampleRate: 1_000).isEmpty)
    }

    func testAWordStartedInAPauseMovesToWhereSpeechResumes() {
        let times = [WordTime(start: 0, end: 0.5), WordTime(start: 0.55, end: 1.0), WordTime(start: 1.1, end: 1.4)]
        let moved = SpeechPauses.movingStarts(of: times, outOf: [0.5...0.9], words: ["one", "two", "three"], duration: 1.4)
        XCTAssertEqual(moved[0], times[0])
        XCTAssertEqual(moved[1].start, 0.9)
        XCTAssertEqual(moved[2], times[2])
    }

    func testSeveralWordsInOnePauseAreSpreadAfterIt() {
        let times = [WordTime(start: 0.6, end: 0.6), WordTime(start: 0.7, end: 0.7), WordTime(start: 1.5, end: 1.8)]
        let moved = SpeechPauses.movingStarts(of: times, outOf: [0.5...0.9], words: ["ab", "ab", "end"], duration: 2)
        XCTAssertEqual(moved[0].start, 0.9, accuracy: 0.001)
        XCTAssertEqual(moved[1].start, 1.2, accuracy: 0.001)
        XCTAssertEqual(moved[2], times[2])
    }

    func testTheHeardPositionTrailsWhatThePlayerHandedOnByTheOutputLatency() {
        // At double speed 0.1 s of latency holds 0.2 s of the sentence.
        XCTAssertEqual(ListenAudioPlayer.heardTime(rendered: 1, from: 2, length: 10, latency: 0.1, rate: 2), 2.8, accuracy: 1e-9)
        // Just after playing from a word, it stays at that word rather than going back before it.
        XCTAssertEqual(ListenAudioPlayer.heardTime(rendered: 0.05, from: 2, length: 10, latency: 0.1, rate: 1), 2)
        XCTAssertEqual(ListenAudioPlayer.heardTime(rendered: 20, from: 2, length: 10, latency: 0.1, rate: 1), 10)
    }
}

// MARK: - Speaking sentences

final class SentenceSpeakerTests: XCTestCase {
    func testSentencesAreMadeTogetherAndEachIsTimed() async throws {
        let synthesizer = FakeSynthesizer()
        let speaker = SentenceSpeaker(synthesizer: synthesizer, aligner: FakeAligner())
        let sentences = ReadingDocument(text: "Cells need energy. They get it from food.").sentences
        let spoken = try await speaker.speak(sentences, voice: "ryan", language: .english)
        XCTAssertEqual(synthesizer.batchSizes, [2])
        XCTAssertEqual(spoken.map(\.wordTimes.count), [3, 5])
        for (time, expected) in zip(spoken[1].wordTimes.map(\.start), [0, 0.1, 0.2, 0.3, 0.4]) {
            XCTAssertEqual(time, expected, accuracy: 1e-9)
        }
    }

    func testANumberIsHighlightedForAllTheWordsItsReadAs() {
        // "1990" is said as "nineteen ninety": the aligner times those two words, and the number on screen spans
        // both, so the word after it starts when it's heard.
        let sentence = ReadingDocument(text: "In 1990 we left.").sentences[0]
        let aligned = ["in", "nineteen", "ninety", "we", "left"].enumerated().map { index, word in
            AlignedWordTime(text: word, start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.3)
        }
        let times = SentenceSpeaker.wordTimes(for: sentence, aligned: aligned, samples: [Float](repeating: 0.3, count: 2_000), sampleRate: 1_000, language: .english)
        for (time, expected) in zip(times.map(\.start), [0, 0.4, 1.2, 1.6]) {
            XCTAssertEqual(time, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(times[1].end, 1.1, accuracy: 1e-9)
    }
}

// MARK: - Numbers

final class SpokenNumbersTests: XCTestCase {
    private func spoken(_ text: String, _ language: ListenLanguage = .english) -> String {
        SpokenNumbers.spoken(text, language: language)
    }

    func testYearsAreReadAsYears() {
        XCTAssertEqual(spoken("In 1990 and 1905, then 2005 and 2024."), "In nineteen ninety and nineteen oh five, then two thousand five and twenty twenty-four.")
        XCTAssertEqual(spoken("By 1900."), "By nineteen hundred.")
    }

    func testCountsDecimalsAndPercentages() {
        XCTAssertEqual(spoken("About 1,250 cells, 3.5 mm and 40% of them."), "About one thousand two hundred fifty cells, three point five mm and forty percent of them.")
        XCTAssertEqual(spoken("It has 7 parts."), "It has seven parts.")
    }

    func testOrdinalsDecadesMoneyAndRanges() {
        XCTAssertEqual(spoken("The 21st and 3rd, in the 1990s."), "The twenty-first and third, in the nineteen nineties.")
        XCTAssertEqual(spoken("It cost $5.50, or $12."), "It cost five dollars fifty cents, or twelve dollars.")
        XCTAssertEqual(spoken("Pages 10-20."), "Pages ten to twenty.")
    }

    func testTextWithoutNumbersAndUnspacedLanguagesAreLeftAlone() {
        XCTAssertEqual(spoken("No numbers here."), "No numbers here.")
        XCTAssertEqual(spoken("2024年", .chinese), "2024年")
        XCTAssertEqual(spoken("COVID19 and B12"), "COVID19 and B12")
    }

    func testOtherLanguagesSpellOutWholeNumbers() {
        XCTAssertEqual(spoken("Es gibt 21 Zellen.", .german), "Es gibt einundzwanzig Zellen.")
    }

    func testEachWordKnowsTheWordsItsSpokenAs() {
        let sentence = ReadingDocument(text: "From 1990 to 2000.").sentences[0]
        XCTAssertEqual(sentence.spokenWords(in: .english), [["From"], ["nineteen", "ninety"], ["to"], ["two", "thousand"]])
        XCTAssertEqual(sentence.voiceText(in: .english), "From nineteen ninety to two thousand.")
    }
}
