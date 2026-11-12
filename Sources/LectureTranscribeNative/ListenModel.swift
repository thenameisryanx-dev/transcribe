import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// The Listen pane: reads text aloud on this Mac, highlights each word as it's spoken, and jumps to any word
/// clicked. Sentences are spoken a few ahead of the one playing, so a long document starts within seconds, and
/// each one is saved once spoken, so it plays at once the next time.
@MainActor
final class ListenModel: ObservableObject {
    enum Playback: Equatable {
        case stopped
        /// Waiting for the sentence to be spoken (or the voice to load) before it can play.
        case waiting
        case playing
        case paused
    }

    enum VoiceState: Equatable {
        case notLoaded
        case loading(progress: Double, message: String)
        case ready
        case failed(String)
    }

    /// Sentences spoken ahead of the one playing.
    static let lookahead = 3
    /// The voice models are released after this long without reading, giving back the ~6 GB of memory they use.
    static let idleUnloadDelay: Duration = .seconds(600)
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4]
    /// Average speaking pace, for the time-left estimate before sentences are spoken.
    static let wordsPerMinute = 150.0

    /// The text in the editor. While reading, the reader shows `document` instead, which can't be edited.
    @Published var text: String = "" {
        didSet { if text != oldValue { scheduleTextSave() } }
    }
    @Published var documentName: String? {
        didSet { defaults.set(documentName, forKey: Keys.documentName) }
    }
    @Published private(set) var document: ReadingDocument?
    @Published private(set) var position: ReadingPosition?
    @Published private(set) var playback: Playback = .stopped
    @Published private(set) var voiceState: VoiceState = .notLoaded
    @Published private(set) var modelsDownloaded = SpeechModelFiles.isDownloaded
    @Published var errorMessage: String?

    @Published var voiceID: String {
        didSet {
            defaults.set(voiceID, forKey: Keys.voice)
            if voiceID != oldValue { voiceOrLanguageChanged() }
        }
    }
    @Published var language: ListenLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            if language != oldValue { voiceOrLanguageChanged() }
        }
    }
    @Published var speed: Double {
        didSet {
            defaults.set(speed, forKey: Keys.speed)
            player.rate = speed
        }
    }

    var isReading: Bool { document != nil }
    var voice: ListenVoice { ListenVoice.named(voiceID) }

    private let speaker: SentenceSpeaker
    private let store: SpokenSentenceStore
    private let defaults: UserDefaults
    private let textFileURL: URL?
    private let player = ListenAudioPlayer()
    private var spoken: [Int: SpokenSentence] = [:]
    /// Bumped for each new document read, so speech made for an earlier one is never played in it.
    private var documentGeneration = 0
    /// The language the document is being read in (`language`, or the one picked from the text).
    private var readingLanguage: ListenLanguage = .english
    private var producer: Task<Void, Never>?
    private var producerToken = 0
    private var loadTask: Task<Void, Error>?
    private var ticker: Task<Void, Never>?
    private var idleUnload: Task<Void, Never>?
    private var textSave: Task<Void, Never>?

    private enum Keys {
        static let voice = "listen.voice"
        static let language = "listen.language"
        static let speed = "listen.speed"
        static let documentName = "listen.documentName"
        static let positions = "listen.positions"
    }

    init(
        speaker: SentenceSpeaker = SentenceSpeaker(synthesizer: Qwen3Synthesizer(), aligner: Qwen3Aligner()),
        store: SpokenSentenceStore = SpokenSentenceStore(root: SpokenSentenceStore.defaultRoot),
        defaults: UserDefaults = .standard,
        textFileURL: URL? = ListenModel.defaultTextFileURL
    ) {
        self.speaker = speaker
        self.store = store
        self.defaults = defaults
        self.textFileURL = textFileURL
        voiceID = defaults.string(forKey: Keys.voice).flatMap { id in ListenVoice.all.first { $0.id == id }?.id } ?? ListenVoice.defaultID
        language = defaults.string(forKey: Keys.language).flatMap(ListenLanguage.init(rawValue:)) ?? .automatic
        let savedSpeed = defaults.double(forKey: Keys.speed)
        speed = Self.speeds.contains(savedSpeed) ? savedSpeed : 1
        documentName = defaults.string(forKey: Keys.documentName)
        if let textFileURL, let saved = try? String(contentsOf: textFileURL, encoding: .utf8) {
            text = saved
        }
        player.rate = speed
        player.onInterrupted = { [weak self] in self?.playerInterrupted() }
        let store = store
        Task.detached(priority: .utility) { store.prune() }
    }

    /// The editor's text is kept between launches in `~/Library/Application Support/LectureTranscribe/listen.txt`.
    nonisolated static var defaultTextFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LectureTranscribe", isDirectory: true)
            .appendingPathComponent("listen.txt", isDirectory: false)
    }

    // MARK: - Reading

    func togglePlayPause() {
        switch playback {
        case .playing, .waiting: pause()
        case .paused, .stopped: play()
        }
    }

    /// Starts reading from the saved place (or the top), or resumes after a pause.
    func play() {
        errorMessage = nil
        if document == nil {
            let document = ReadingDocument(text: text)
            guard !document.isEmpty else { return }
            self.document = document
            documentGeneration += 1
            readingLanguage = language.resolved(for: text)
            spoken = [:]
            position = savedPosition(in: document) ?? ReadingPosition(sentence: 0, word: 0)
        }
        if playback == .paused, player.canResume {
            player.resume()
            playback = .playing
            startTicker()
            return
        }
        playCurrent()
    }

    func pause() {
        guard playback == .playing || playback == .waiting else { return }
        player.pause()
        playback = .paused
        stopTicker()
        savePosition()
        scheduleIdleUnload()
    }

    /// Stops reading and goes back to editing the text. The place is kept for next time.
    func editText() {
        savePosition()
        player.stop()
        producer?.cancel()
        producer = nil
        stopTicker()
        document = nil
        position = nil
        spoken = [:]
        playback = .stopped
        scheduleIdleUnload()
    }

    /// Jumps to the word at a place in the text (a click on it).
    func jump(toLocation location: Int) {
        guard let document, let target = document.position(at: location) else { return }
        jump(to: target)
    }

    func jump(to target: ReadingPosition) {
        guard let document, document.sentences.indices.contains(target.sentence) else { return }
        position = target
        let wasPaused = playback == .paused || playback == .stopped
        if wasPaused {
            // Moving while paused shows the new place; Play starts there.
            player.stop()
            playback = .paused
            savePosition()
            startProducer()
            return
        }
        playCurrent()
    }

    func nextSentence() {
        guard let document, let position, position.sentence + 1 < document.sentences.count else { return }
        jump(to: ReadingPosition(sentence: position.sentence + 1, word: 0))
    }

    /// Back to the start of this sentence, or to the one before when already at its start.
    func previousSentence() {
        guard let position else { return }
        let elapsed = player.currentTime ?? 0
        if position.word > 0 || elapsed > 1.5 {
            jump(to: ReadingPosition(sentence: position.sentence, word: 0))
        } else if position.sentence > 0 {
            jump(to: ReadingPosition(sentence: position.sentence - 1, word: 0))
        }
    }

    var canGoBack: Bool { position.map { $0.sentence > 0 || $0.word > 0 } ?? false }
    var canGoForward: Bool {
        guard let document, let position else { return false }
        return position.sentence + 1 < document.sentences.count
    }

    /// Where the current sentence and word sit in the text, for highlighting.
    var currentSentenceRange: NSRange? {
        guard let document, let position, document.sentences.indices.contains(position.sentence) else { return nil }
        return document.sentences[position.sentence].range
    }

    var currentWordRange: NSRange? {
        guard let document, let position else { return nil }
        return document.word(at: position)?.range
    }

    /// How far through the document reading is, from 0 to 1, by words.
    var progress: Double {
        guard let document, let position, document.wordCount > 0 else { return 0 }
        let before = document.sentences.prefix(position.sentence).reduce(0) { $0 + $1.words.count }
        return Double(before + position.word) / Double(document.wordCount)
    }

    /// Minutes left at the chosen speed, estimated from the words left.
    var minutesLeft: Double? {
        guard let document, let position else { return nil }
        let before = document.sentences.prefix(position.sentence).reduce(0) { $0 + $1.words.count }
        let left = document.wordCount - before - position.word
        return Double(left) / (Self.wordsPerMinute * speed)
    }

    private func playCurrent() {
        guard let position else { return }
        startProducer()
        if let sentence = spoken[position.sentence] {
            start(sentence, at: position)
        } else {
            player.stop()
            playback = .waiting
            stopTicker()
        }
    }

    private func start(_ sentence: SpokenSentence, at position: ReadingPosition) {
        let time = sentence.wordTimes.indices.contains(position.word) ? sentence.wordTimes[position.word].start : 0
        let index = position.sentence
        do {
            try player.play(sentence, from: time) { [weak self] in
                self?.sentenceFinished(index)
            }
            playback = .playing
            cancelIdleUnload()
            startTicker()
        } catch {
            fail("Couldn't play the audio: \(error.localizedDescription)")
        }
    }

    private func sentenceFinished(_ index: Int) {
        guard let document, position?.sentence == index else { return }
        dropFarSentences()
        guard index + 1 < document.sentences.count else {
            finishedDocument()
            return
        }
        position = ReadingPosition(sentence: index + 1, word: 0)
        playCurrent()
        if playback == .waiting { savePosition() }
    }

    private func finishedDocument() {
        stopTicker()
        playback = .stopped
        position = ReadingPosition(sentence: 0, word: 0)
        clearSavedPosition()
        player.stop()
        producer?.cancel()
        producer = nil
        scheduleIdleUnload()
    }

    private func playerInterrupted() {
        guard playback == .playing else { return }
        // The device changed; resume on the new one from the word that was playing.
        playCurrent()
    }

    private func fail(_ message: String) {
        errorMessage = message
        player.stop()
        stopTicker()
        if playback != .stopped { playback = .paused }
    }

    private func voiceOrLanguageChanged() {
        guard document != nil else { return }
        readingLanguage = language.resolved(for: text)
        spoken = [:]
        producer?.cancel()
        producer = nil
        if playback == .playing || playback == .waiting {
            playCurrent()
        }
    }

    // MARK: - Highlight

    /// Follows the audio, moving the highlight to the word being spoken.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard playback == .playing, let position, let sentence = spoken[position.sentence],
              let time = player.currentTime,
              let word = WordTimingMatcher.wordIndex(at: time, in: sentence.wordTimes),
              word != position.word
        else { return }
        self.position = ReadingPosition(sentence: position.sentence, word: word)
    }

    // MARK: - Speaking ahead

    /// Speaks the sentence being read and the few after it, one at a time, in reading order. It follows `position`,
    /// so after a jump it moves on to the new place by itself.
    private func startProducer() {
        guard producer == nil else { return }
        producerToken += 1
        let token = producerToken
        producer = Task { [weak self] in
            await self?.produce()
            // A producer cancelled and replaced while it finished mustn't clear its replacement.
            if self?.producerToken == token { self?.producer = nil }
        }
    }

    private func produce() async {
        do {
            try await loadVoice()
        } catch is CancellationError {
            return
        } catch {
            fail(error.localizedDescription)
            return
        }

        while !Task.isCancelled {
            guard let document, let position else { return }
            let window = position.sentence..<min(position.sentence + Self.lookahead + 1, document.sentences.count)
            guard let index = window.first(where: { spoken[$0] == nil }) else {
                // Everything near is ready; check again once reading moves on.
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let sentence = document.sentences[index]
            let generation = documentGeneration
            let voice = voiceID
            let language = readingLanguage
            let key = SpokenSentenceStore.key(text: sentence.spokenText, engine: speaker.identifier, voice: voice, language: language.rawValue)
            let store = store
            let speaker = speaker
            let result: SpokenSentence
            do {
                if let saved = await Task.detached(operation: { store.load(key) }).value,
                   saved.wordTimes.count == sentence.words.count {
                    result = saved
                } else {
                    result = try await speaker.speak(sentence, voice: voice, language: language)
                    Task.detached(priority: .utility) { store.save(result, key: key) }
                }
            } catch is CancellationError {
                return
            } catch {
                fail("Couldn't read “\(sentence.spokenText.prefix(60))”: \(error.localizedDescription)")
                return
            }
            // The text, voice or language may have changed while it was being spoken.
            guard !Task.isCancelled, generation == documentGeneration, voice == voiceID, language == readingLanguage else { continue }
            spoken[index] = result
            if playback == .waiting, self.position?.sentence == index, let position = self.position {
                start(result, at: position)
            }
        }
    }

    /// Keeps only sentences near the one playing in memory (an hour of speech is about 350 MB); the rest are on disk.
    private func dropFarSentences() {
        guard let position else { return }
        let keep = (position.sentence - 2)...(position.sentence + Self.lookahead + 1)
        spoken = spoken.filter { keep.contains($0.key) }
    }

    // MARK: - Voice models

    /// Downloads (the first time) and loads the voice and the aligner.
    func loadVoice() async throws {
        if speaker.synthesizer.isLoaded, speaker.aligner.isLoaded {
            voiceState = .ready
            return
        }
        if let loadTask {
            try await loadTask.value
            return
        }
        let speaker = speaker
        let task = Task { [weak self] in
            let report: @Sendable (Double, String) -> Void = { fraction, message in
                Task { @MainActor in
                    guard let self, case .loading = self.voiceState else { return }
                    self.voiceState = .loading(progress: min(max(fraction, 0), 1), message: message)
                }
            }
            // The voice is about 2.5 GB of the 3.5 GB, so it takes most of the bar.
            try await speaker.synthesizer.load { fraction, message in report(fraction * 0.7, message) }
            try await speaker.aligner.load { fraction, message in report(0.7 + fraction * 0.3, message) }
        }
        loadTask = task
        voiceState = .loading(progress: 0, message: modelsDownloaded ? "Loading the voice…" : "Downloading the voice…")
        defer { loadTask = nil }
        do {
            try await task.value
            voiceState = .ready
            modelsDownloaded = true
        } catch {
            voiceState = error is CancellationError ? .notLoaded : .failed(Self.describe(error))
            throw error
        }
    }

    /// Downloads the voice models now (from Settings), so the first Play doesn't wait for them.
    func downloadVoice() {
        Task {
            do { try await loadVoice() } catch {}
            scheduleIdleUnload()
        }
    }

    func deleteVoiceModels() {
        editText()
        unloadVoice()
        do {
            try SpeechModelFiles.removeAll()
        } catch {
            errorMessage = "Couldn't delete the voice models: \(error.localizedDescription)"
        }
        modelsDownloaded = SpeechModelFiles.isDownloaded
    }

    func clearSavedSpeech() {
        let store = store
        Task.detached { store.removeAll() }
    }

    func savedSpeechSize() async -> Int64 {
        let store = store
        return await Task.detached { store.size() }.value
    }

    private func unloadVoice() {
        speaker.synthesizer.unload()
        speaker.aligner.unload()
        voiceState = .notLoaded
    }

    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled, let self, self.playback != .playing, self.playback != .waiting else { return }
            self.producer?.cancel()
            self.producer = nil
            self.unloadVoice()
        }
    }

    private func cancelIdleUnload() {
        idleUnload?.cancel()
        idleUnload = nil
    }

    private static func describe(_ error: Error) -> String {
        let message = error.localizedDescription
        if (error as NSError).domain == NSURLErrorDomain {
            return "Couldn't download the voice. Check your internet connection and try again. (\(message))"
        }
        return "Couldn't load the voice: \(message)"
    }

    // MARK: - Remembering the place

    /// The place in each document read, by a hash of its text, so reopening one carries on where it stopped.
    private func positionKey(_ document: ReadingDocument) -> String {
        SpokenSentenceStore.key(text: document.text, engine: "position", voice: "", language: "")
    }

    private func savedPosition(in document: ReadingDocument) -> ReadingPosition? {
        guard let saved = defaults.dictionary(forKey: Keys.positions)?[positionKey(document)] as? [Int], saved.count == 2,
              document.sentences.indices.contains(saved[0])
        else { return nil }
        return ReadingPosition(sentence: saved[0], word: 0)
    }

    private func savePosition() {
        guard let document, let position else { return }
        var positions = defaults.dictionary(forKey: Keys.positions) ?? [:]
        positions[positionKey(document)] = [position.sentence, position.word]
        // Only the most recent documents matter; keep the list small.
        if positions.count > 50 { positions.removeValue(forKey: positions.keys.first!) }
        defaults.set(positions, forKey: Keys.positions)
    }

    private func clearSavedPosition() {
        guard let document else { return }
        var positions = defaults.dictionary(forKey: Keys.positions) ?? [:]
        positions.removeValue(forKey: positionKey(document))
        defaults.set(positions, forKey: Keys.positions)
    }

    private func scheduleTextSave() {
        guard let textFileURL else { return }
        textSave?.cancel()
        let text = text
        textSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: textFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: textFileURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Opening files

    static let openableTypes: [UTType] = [
        .pdf, .plainText, .rtf, .rtfd, .html,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
        UTType("net.daringfireball.markdown"),
    ].compactMap { $0 }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openableTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PDF, Word document or text file to listen to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let opened = try ListenDocumentImporter.text(from: url)
            guard !opened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "“\(url.lastPathComponent)” has no text to read. (A scanned PDF has only pictures of text.)"
                return
            }
            editText()
            text = opened
            documentName = url.lastPathComponent
            play()
        } catch {
            errorMessage = "Couldn't open “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    /// Starts again with empty text.
    func clearText() {
        editText()
        text = ""
        documentName = nil
    }
}

/// Gets the text out of the files the Listen pane opens.
enum ListenDocumentImporter {
    enum ImportError: LocalizedError {
        case unreadable

        var errorDescription: String? { "The file couldn't be read." }
    }

    static func text(from url: URL) throws -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            guard let pdf = PDFDocument(url: url) else { throw ImportError.unreadable }
            let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
            return unwrapLines(pages.joined(separator: "\n\n"))
        }
        if let type, type.conforms(to: .plainText) || type.conforms(to: UTType("net.daringfireball.markdown") ?? .plainText) {
            var encoding = String.Encoding.utf8
            return try String(contentsOf: url, usedEncoding: &encoding)
        }
        // Word (.docx, .doc), RTF, HTML and OpenDocument text.
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return attributed.string
        }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }

    /// PDFs break lines where the page did, mid-sentence. Joins those lines back up (and words hyphenated across
    /// them), keeping blank lines between paragraphs.
    static func unwrapLines(_ text: String) -> String {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: /\n[ \t]*\n/, omittingEmptySubsequences: true)
            .map(String.init)
        return paragraphs.map { paragraph in
            var joined = paragraph.replacingOccurrences(of: #"(\p{Ll})-\n(\p{Ll})"#, with: "$1$2", options: .regularExpression)
            joined = joined.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: " ", options: .regularExpression)
            return joined.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }
}
