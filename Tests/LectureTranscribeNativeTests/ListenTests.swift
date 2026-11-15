import Foundation
import XCTest

@testable import LectureTranscribeNative

// MARK: - Fakes

/// A voice that "speaks" a sentence as a short burst of silence and records what it was asked to say, so the
/// reader can be tested without downloading or running the real models. Each word lasts `secondsPerWord`, and each
/// sentence takes `secondsToMake`.
final class FakeSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    let identifier: String
    let secondsPerWord: Double
    let secondsToMake: Double
    static let sampleRate = 1_000
    private let lock = NSLock()
    private var said: [String] = []
    private var loaded = false

    init(identifier: String = "fake-voice", secondsPerWord: Double = 0.1, secondsToMake: Double = 0) {
        self.identifier = identifier
        self.secondsPerWord = secondsPerWord
        self.secondsToMake = secondsToMake
    }

    var spoken: [String] { lock.withLock { said } }
    var isLoaded: Bool { lock.withLock { loaded } }

    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        progress(1, "Loaded")
        lock.withLock { loaded = true }
    }

    func synthesize(_ text: String, voice: String, language: ListenLanguage) async throws -> (samples: [Float], sampleRate: Int) {
        if secondsToMake > 0 { try await Task.sleep(for: .seconds(secondsToMake)) }
        lock.withLock { said.append(text) }
        let words = text.split(separator: " ").count
        return ([Float](repeating: 0, count: Int(Double(max(words, 1) * Self.sampleRate) * secondsPerWord)), Self.sampleRate)
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

/// A Listen model with fake voices (`synthesizer` for Kokoro, the default engine, and `qwen` for Qwen3-TTS), and its
/// own saved text, settings and saved speech in `directory`.
@MainActor
func makeTestListenModel(
    directory: URL,
    synthesizer: FakeSynthesizer = FakeSynthesizer(),
    qwen: FakeSynthesizer = FakeSynthesizer(identifier: "fake-qwen"),
    player: ListenAudioPlayer? = nil,
    mlxWork: MLXWorkGate = MLXWorkGate(),
    defaults: UserDefaults = UserDefaults(suiteName: "ListenTests.\(UUID().uuidString)")!
) -> ListenModel {
    ListenModel(
        synthesizers: [.kokoro: synthesizer, .qwen: qwen],
        aligner: FakeAligner(),
        store: SpokenSentenceStore(root: directory.appendingPathComponent("listen_audio", isDirectory: true)),
        defaults: defaults,
        textFileURL: directory.appendingPathComponent("listen.txt"),
        player: player,
        mlxWork: mlxWork
    )
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
        // Speaking ahead stopped, and no more MLX work can start.
        XCTAssertLessThanOrEqual(synthesizer.spoken.count, spokenAtQuit + 1)
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


    @MainActor
    func testPlaySpeaksTheSentencesAheadInOrder() async {
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer)
        model.text = (1...8).map { "Sentence number \($0) is here." }.joined(separator: " ")
        model.play()
        XCTAssertTrue(model.isReading)
        XCTAssertEqual(model.position, ReadingPosition(sentence: 0, word: 0))

        await waitUntil { synthesizer.spoken.count >= ListenModel.lookahead + 1 }
        // The one being read and the few after it, in order, and no further.
        XCTAssertEqual(Array(synthesizer.spoken.prefix(ListenModel.lookahead + 1)), (1...(ListenModel.lookahead + 1)).map { "Sentence number \($0) is here." })
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(synthesizer.spoken.contains("Sentence number 8 is here."))
        model.editText()
    }

    @MainActor
    func testASlowAudioDeviceDoesNotHoldUpReading() async {
        // Waking a sleeping USB or Bluetooth speaker can take seconds; that used to freeze the app on Play, so
        // nothing past the first sentence was spoken until the device was up.
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, player: makeSlowDevicePlayer(delay: 1.5))
        model.text = (1...8).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let started = Date()
        model.play()

        await waitUntil({ synthesizer.spoken.count >= ListenModel.lookahead + 1 }, timeout: 1)
        XCTAssertEqual(synthesizer.spoken.count, ListenModel.lookahead + 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(model.playback, .waiting)

        // Once the device is up (here, once it fails), reading goes on from there.
        await waitUntil { model.errorMessage != nil }
        XCTAssertEqual(model.errorMessage, "Couldn't play the audio: The device didn't start.")
        XCTAssertEqual(model.playback, .paused)
        model.editText()
    }

    @MainActor
    func testPausingWhileTheAudioDeviceStartsStaysPaused() async {
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, player: makeSlowDevicePlayer(delay: 0.5))
        model.text = "One sentence. And another."
        model.play()
        await waitUntil { synthesizer.spoken.count >= 1 && model.playback == .waiting }
        model.pause()
        XCTAssertEqual(model.playback, .paused)

        // The device finishing its start doesn't play the sentence (or report on it) after the pause.
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(model.playback, .paused)
        XCTAssertNil(model.errorMessage)
        model.editText()
    }

    @MainActor
    func testJumpingToAWordReadsFromThere() async {
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer)
        model.text = (1...10).map { "Line \($0) goes here." }.joined(separator: " ")
        model.play()
        model.pause()

        let target = (model.text as NSString).range(of: "Line 9")
        model.jump(toLocation: target.location + 5)
        XCTAssertEqual(model.position, ReadingPosition(sentence: 8, word: 1))
        XCTAssertEqual(model.currentWordRange.map { (model.text as NSString).substring(with: $0) }, "9")
        await waitUntil { synthesizer.spoken.contains("Line 9 goes here.") }
        XCTAssertTrue(synthesizer.spoken.contains("Line 9 goes here."))
        model.editText()
    }

    @MainActor
    func testReadingPicksUpWhereItStopped() async {
        let model = makeTestListenModel(directory: directory)
        model.text = "First. Second. Third. Fourth."
        model.play()
        model.pause()
        model.jump(to: ReadingPosition(sentence: 2, word: 0))
        model.editText()
        XCTAssertFalse(model.isReading)

        model.play()
        XCTAssertEqual(model.position?.sentence, 2)
        model.editText()
    }

    @MainActor
    func testSpeechIsSavedSoItIsNotMadeTwice() async {
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer)
        model.text = "Only one sentence here."
        model.play()
        await waitUntil { synthesizer.spoken.count == 1 }
        // Saving happens in the background.
        let store = SpokenSentenceStore(root: directory.appendingPathComponent("listen_audio", isDirectory: true))
        await waitUntil { store.size() > 0 }
        model.editText()

        model.play()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(synthesizer.spoken.count, 1)
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

    /// A defaults suite where the voices have already been measured making speech this many times slower than it
    /// plays.
    private func defaults(makingRate rate: Double, for engine: ListenEngine) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ListenTests.\(UUID().uuidString)")!
        defaults.set(rate, forKey: "listen.makingRate.\(engine.rawValue)")
        return defaults
    }

    /// A device that fails at once, recording how many sentences the voice had made when reading started.
    @MainActor
    private func recordingStartPlayer(_ voice: FakeSynthesizer, into madeAtStart: Locked<Int?>) -> ListenAudioPlayer {
        ListenAudioPlayer { _ in
            if madeAtStart.value == nil { madeAtStart.value = voice.spoken.count }
            throw SlowDeviceError()
        }
    }

    @MainActor
    func testAVoiceSlowerThanTheReadingGetsAHeadStart() async {
        // Speech that takes twice as long to make as to play: starting with 10 sentences left, reading must wait
        // for over half of them (with the safety margin, 6) or it would catch up with the voice.
        let qwen = FakeSynthesizer(identifier: "fake-qwen", secondsPerWord: 0.01, secondsToMake: 0.02)
        let madeAtStart = Locked<Int?>(nil)
        let model = makeTestListenModel(directory: directory, qwen: qwen, player: recordingStartPlayer(qwen, into: madeAtStart),
                                        defaults: defaults(makingRate: 2, for: .qwen))
        model.engine = .qwen
        model.text = (1...10).map { "Sentence number \($0) is here." }.joined(separator: " ")
        model.play()
        await waitUntil { qwen.spoken.count >= 1 }
        XCTAssertEqual(model.playback, .waiting)
        XCTAssertNotNil(model.headStartWait)

        await waitUntil { madeAtStart.value != nil }
        XCTAssertGreaterThanOrEqual(madeAtStart.value ?? 0, 6)
        // It makes the rest of the document too, well past the few sentences ahead a fast voice makes.
        await waitUntil { qwen.spoken.count == 10 }
        XCTAssertEqual(qwen.spoken.count, 10)
        model.editText()
    }

    @MainActor
    func testStartNowSkipsTheHeadStart() async {
        let qwen = FakeSynthesizer(identifier: "fake-qwen", secondsPerWord: 0.01, secondsToMake: 0.05)
        let madeAtStart = Locked<Int?>(nil)
        let model = makeTestListenModel(directory: directory, qwen: qwen, player: recordingStartPlayer(qwen, into: madeAtStart),
                                        defaults: defaults(makingRate: 3, for: .qwen))
        model.engine = .qwen
        model.text = (1...20).map { "Sentence number \($0) is here." }.joined(separator: " ")
        model.play()
        await waitUntil { qwen.spoken.count >= 1 }
        XCTAssertNotNil(model.headStartWait)
        model.startNow()
        await waitUntil { madeAtStart.value != nil }
        XCTAssertLessThan(madeAtStart.value ?? 99, 5)
        model.editText()
    }

    @MainActor
    func testAFastVoiceStartsAtOnceAndOnlyMakesAFewAhead() async {
        let kokoro = FakeSynthesizer(secondsPerWord: 0.01)
        let madeAtStart = Locked<Int?>(nil)
        let model = makeTestListenModel(directory: directory, synthesizer: kokoro, player: recordingStartPlayer(kokoro, into: madeAtStart),
                                        defaults: defaults(makingRate: 0.5, for: .kokoro))
        model.text = (1...10).map { "Sentence number \($0) is here." }.joined(separator: " ")
        model.play()
        await waitUntil { madeAtStart.value != nil }
        XCTAssertNil(model.headStartWait)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(kokoro.spoken.count, ListenModel.lookahead + 1)
        model.editText()
    }

    @MainActor
    func testFasterReadingNeedsAHeadStartEvenFromAFastVoice() async {
        // Half as long to make as to play is fine at 1×, but not at 4×.
        let kokoro = FakeSynthesizer(secondsPerWord: 0.01)
        let defaults = defaults(makingRate: 0.5, for: .kokoro)
        defaults.set(4.0, forKey: "listen.speed")
        let model = makeTestListenModel(directory: directory, synthesizer: kokoro, player: makeSlowDevicePlayer(delay: 0), defaults: defaults)
        model.text = (1...10).map { "Sentence number \($0) is here." }.joined(separator: " ")
        model.play()
        await waitUntil { kokoro.spoken.count == 10 }
        XCTAssertEqual(kokoro.spoken.count, 10)
        model.editText()
    }

    @MainActor
    func testTheVoicesSpeedIsMeasuredAndRemembered() async {
        // Sentences of a little over a second, made in a fraction of that.
        let qwen = FakeSynthesizer(identifier: "fake-qwen", secondsPerWord: 0.25)
        let defaults = defaults(makingRate: 2, for: .qwen)
        let model = makeTestListenModel(directory: directory, qwen: qwen, player: makeSlowDevicePlayer(delay: 0), defaults: defaults)
        model.engine = .qwen
        model.text = (1...3).map { "Sentence number \($0) is here." }.joined(separator: " ")
        model.play()
        await waitUntil { qwen.spoken.count == 3 }
        XCTAssertLessThan(defaults.double(forKey: "listen.makingRate.qwen"), 2)
        model.editText()
    }

    @MainActor
    func testKokoroIsTheDefaultVoiceModel() {
        let model = makeTestListenModel(directory: directory)
        XCTAssertEqual(model.engine, .kokoro)
        XCTAssertEqual(model.voiceID, "af_heart")
        XCTAssertEqual(model.voice.name, "Heart")
    }

    @MainActor
    func testEachVoiceModelKeepsItsOwnVoice() {
        // A voice chosen before there was a choice of model was a Qwen3-TTS voice; it's still there for Qwen3-TTS.
        let defaults = UserDefaults(suiteName: "ListenTests.\(UUID().uuidString)")!
        defaults.set("aiden", forKey: "listen.voice")
        let model = makeTestListenModel(directory: directory, defaults: defaults)
        XCTAssertEqual(model.voiceID, "af_heart")

        model.voiceID = "bm_george"
        model.engine = .qwen
        XCTAssertEqual(model.voiceID, "aiden")
        model.engine = .kokoro
        XCTAssertEqual(model.voiceID, "bm_george")

        // And they're remembered between launches.
        let relaunched = makeTestListenModel(directory: directory, defaults: defaults)
        XCTAssertEqual(relaunched.engine, .kokoro)
        XCTAssertEqual(relaunched.voiceID, "bm_george")
    }

    @MainActor
    func testSwitchingVoiceModelReadsWithTheNewOne() async {
        let kokoro = FakeSynthesizer()
        let qwen = FakeSynthesizer(identifier: "fake-qwen")
        // A device that fails at once, so the test doesn't wait on this Mac's speakers.
        let model = makeTestListenModel(directory: directory, synthesizer: kokoro, qwen: qwen, player: makeSlowDevicePlayer(delay: 0))
        model.text = (1...8).map { "Sentence number \($0) is here." }.joined(separator: " ")
        model.play()
        await waitUntil { kokoro.spoken.count >= 1 }
        XCTAssertTrue(qwen.spoken.isEmpty)

        model.engine = .qwen
        model.play()
        await waitUntil { qwen.spoken.count >= 1 }
        XCTAssertEqual(qwen.spoken.first, "Sentence number 1 is here.")
        // Only one voice is kept in memory.
        XCTAssertFalse(kokoro.isLoaded)
        XCTAssertTrue(qwen.isLoaded)
        model.editText()
    }

    @MainActor
    func testALanguageTheVoiceModelCantReadSaysSoInsteadOfReading() async {
        let kokoro = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: kokoro)
        model.text = "Привет, как у тебя сегодня дела? Это очень длинное предложение на русском языке."
        model.play()
        await waitUntil { model.errorMessage != nil }
        XCTAssertEqual(model.errorMessage, "Kokoro can't read Russian. Choose another voice model from the voice menu to hear this text.")
        XCTAssertTrue(kokoro.spoken.isEmpty)
        XCTAssertFalse(model.engine.languages.contains(.russian))

        // Qwen3-TTS reads it.
        model.engine = .qwen
        XCTAssertNil(model.errorMessage)
        model.play()
        XCTAssertNil(model.errorMessage)
        model.editText()
    }

    func testKokoroVoicesAreNamedFromTheirFiles() {
        XCTAssertEqual(ListenVoice.kokoro.count, 50)
        XCTAssertEqual(ListenVoice.kokoroVoice("bf_emma"), ListenVoice(id: "bf_emma", name: "Emma", summary: "Female, British", nativeLanguage: .english))
        XCTAssertEqual(ListenVoice.kokoroVoice("zm_yunxi")?.nativeLanguage, .chinese)
        XCTAssertEqual(ListenVoice.kokoroVoice("zm_yunxi")?.summary, "Male")
        // Every voice speaks a language Kokoro reads, and the default is one of them.
        XCTAssertTrue(ListenVoice.kokoro.allSatisfy { ListenEngine.kokoro.reads($0.nativeLanguage) })
        for engine in ListenEngine.allCases {
            XCTAssertNotNil(engine.voice(engine.defaultVoiceID))
        }
    }

    @MainActor
    func testAutomaticLanguageFollowsTheText() {
        XCTAssertEqual(ListenLanguage.automatic.resolved(for: "Bonjour tout le monde, comment allez-vous aujourd'hui ?"), .french)
        XCTAssertEqual(ListenLanguage.automatic.resolved(for: "The quick brown fox jumps over the lazy dog."), .english)
        XCTAssertEqual(ListenLanguage.german.resolved(for: "The quick brown fox."), .german)
    }
}
