import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// The Listen pane: reads text aloud on this Mac, highlights each word as it's spoken, and jumps to any word clicked.
///
/// Pressing Play first makes the speech for the whole document, several sentences at once, while the pane shows how
/// far along that is (and can be cancelled); the reader opens once it's all made. Qwen3-TTS makes speech about as
/// fast as it plays one sentence at a time, so reading while it was still being made kept stopping to wait. Every
/// sentence is saved once made, so a document read before (or a cancelled one, as far as it got) is ready at once.
@MainActor
final class ListenModel: ObservableObject {
    enum Stage: Equatable {
        /// The text can be edited.
        case editing
        /// The speech for `document` is being made.
        case preparing
        /// `document` is being read.
        case reading
    }

    enum Playback: Equatable {
        case stopped
        /// Waiting for the sentence to load (or the audio device to start) before it can play.
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

    /// How making the speech for a document is going.
    struct Preparation: Equatable {
        /// Sentences ready, of `total` (those saved from before count as ready).
        var done: Int
        var total: Int
        /// Words made so far this time, of the `wordsToMake` that weren't saved, for the time-left estimate.
        var wordsMade = 0
        var wordsToMake: Int
        /// Seconds spent making them, from when the voice was ready.
        var secondsSpent = 0.0

        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

        /// About how many seconds are left, once a batch has been made to go by.
        var secondsLeft: Double? {
            guard wordsMade > 0, secondsSpent > 0 else { return nil }
            return secondsSpent / Double(wordsMade) * Double(max(wordsToMake - wordsMade, 0))
        }
    }

    /// Sentences loaded from disk ahead of the one playing.
    static let lookahead = 3
    /// The voice models are released this long after making speech, giving back the ~4 GB of memory they use.
    static let idleUnloadDelay: Duration = .seconds(120)
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4]
    /// Average speaking pace, for the time-left estimate.
    static let wordsPerMinute = 150.0

    /// The text in the editor. While preparing and reading, the pane shows `document` instead, which can't be edited.
    @Published var text: String = "" {
        didSet { if text != oldValue { scheduleTextSave() } }
    }
    @Published var documentName: String? {
        didSet { defaults.set(documentName, forKey: Keys.documentName) }
    }
    @Published private(set) var stage: Stage = .editing
    @Published private(set) var document: ReadingDocument?
    @Published private(set) var preparation: Preparation?
    @Published private(set) var position: ReadingPosition?
    @Published private(set) var playback: Playback = .stopped
    /// Loading the downloaded voice into memory, which happens when speech is made.
    @Published private(set) var voiceState: VoiceState = .notLoaded
    /// Getting the voice's files onto this Mac, which happens once, before Play is offered.
    @Published private(set) var voiceDownload: VoiceDownload
    /// The download just finished, so the pane can say the voice is ready until Play is first pressed.
    @Published private(set) var voiceJustDownloaded = false
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
    /// How many sentences the voice makes at once. More is faster, but keeps the GPU busier.
    @Published var sentencesAtOnce: Int {
        didSet { defaults.set(sentencesAtOnce, forKey: Keys.sentencesAtOnce) }
    }

    var isReading: Bool { stage == .reading }
    var isPreparing: Bool { stage == .preparing }
    /// Whether the voice model's files are on disk.
    var modelsDownloaded: Bool { voiceDownload == .downloaded }
    var voice: ListenVoice { ListenVoiceModel.voice(voiceID) ?? ListenVoiceModel.voices[0] }

    private let speaker: SentenceSpeaker
    private var isVoiceLoaded: Bool { speaker.synthesizer.isLoaded && speaker.aligner.isLoaded }
    private let store: SpokenSentenceStore
    private let defaults: UserDefaults
    private let textFileURL: URL?
    private let player: ListenAudioPlayer
    private let mlxWork: MLXWorkGate
    private let downloader: any SpeechModelDownloader
    private var downloadTask: Task<Void, Never>?
    /// Counts downloads started, so a cancelled one that finishes late can't change the state of the next.
    private var downloadGeneration = 0
    /// The sentences near the one playing, loaded from disk.
    private var spoken: [Int: SpokenSentence] = [:]
    /// The sentence being started (while the audio device wakes), so it isn't started twice.
    private var startingSentence: Int?
    /// The language the document is read in (`language`, or the one picked from the text).
    private var readingLanguage: ListenLanguage = .english
    private var preparer: Task<Void, Never>?
    private var loader: Task<Void, Never>?
    private var loadTask: Task<Void, Error>?
    private var ticker: Task<Void, Never>?
    private var idleUnload: Task<Void, Never>?
    private var textSave: Task<Void, Never>?

    private enum Keys {
        static let voice = "listen.voice"
        static let language = "listen.language"
        static let speed = "listen.speed"
        static let sentencesAtOnce = "listen.sentencesAtOnce"
        static let documentName = "listen.documentName"
        static let positions = "listen.positions"
    }

    init(
        synthesizer: any SpeechSynthesizer = Qwen3Synthesizer(),
        aligner: any WordAligner = Qwen3Aligner(),
        store: SpokenSentenceStore = SpokenSentenceStore(root: SpokenSentenceStore.defaultRoot),
        defaults: UserDefaults = .standard,
        textFileURL: URL? = ListenModel.defaultTextFileURL,
        player: ListenAudioPlayer? = nil,
        mlxWork: MLXWorkGate = .shared,
        downloader: any SpeechModelDownloader = HubSpeechModelDownloader()
    ) {
        self.player = player ?? ListenAudioPlayer()
        self.mlxWork = mlxWork
        speaker = SentenceSpeaker(synthesizer: synthesizer, aligner: aligner)
        self.store = store
        self.defaults = defaults
        self.textFileURL = textFileURL
        self.downloader = downloader
        voiceDownload = downloader.isDownloaded() ? .downloaded : .notDownloaded
        voiceID = defaults.string(forKey: Keys.voice).flatMap { ListenVoiceModel.voice($0)?.id } ?? ListenVoiceModel.defaultVoiceID
        language = defaults.string(forKey: Keys.language).flatMap(ListenLanguage.init(rawValue:)) ?? .automatic
        let savedSpeed = defaults.double(forKey: Keys.speed)
        speed = Self.speeds.contains(savedSpeed) ? savedSpeed : 1
        let savedAtOnce = defaults.integer(forKey: Keys.sentencesAtOnce)
        sentencesAtOnce = ListenVoiceModel.sentencesAtOnceChoices.contains(savedAtOnce)
            ? savedAtOnce : ListenVoiceModel.defaultSentencesAtOnce()
        documentName = defaults.string(forKey: Keys.documentName)
        if let textFileURL, let saved = try? String(contentsOf: textFileURL, encoding: .utf8) {
            text = saved
        }
        self.player.rate = speed
        self.player.onInterrupted = { [weak self] in self?.playerInterrupted() }
        let store = store
        Task.detached(priority: .utility) { store.prune() }
    }

    /// The editor's text is kept between launches in `~/Library/Application Support/LectureTranscribe/listen.txt`.
    nonisolated static var defaultTextFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LectureTranscribe", isDirectory: true)
            .appendingPathComponent("listen.txt", isDirectory: false)
    }

    // MARK: - Preparing

    /// Makes the speech for the text (whatever isn't saved yet), then opens the reader. While reading, resumes.
    func play() {
        errorMessage = nil
        voiceJustDownloaded = false
        switch stage {
        case .editing:
            // Play isn't offered until the voice is downloaded; the pane offers Download Voice instead.
            guard modelsDownloaded else { return }
            let document = ReadingDocument(text: text)
            guard !document.isEmpty else { return }
            self.document = document
            readingLanguage = language.resolved(for: text)
            prepare(thenReadFrom: savedPosition(in: document), startPlaying: true)
        case .preparing:
            return
        case .reading:
            if playback == .paused, player.canResume {
                player.resume()
                playback = .playing
                startTicker()
                return
            }
            playCurrent()
        }
    }

    /// Makes every sentence of `document` that isn't saved, `sentencesAtOnce` at a time, then reads from `place`
    /// (the top when nil). Reading starts by itself only when nothing needed making (`startPlaying`); after a wait the
    /// reader opens paused, so it doesn't start talking while nobody's listening.
    private func prepare(thenReadFrom place: ReadingPosition?, startPlaying: Bool) {
        guard let document else { return }
        player.stop()
        stopTicker()
        loader?.cancel()
        loader = nil
        preparer?.cancel()
        spoken = [:]
        startingSentence = nil
        playback = .stopped
        stage = .preparing
        cancelIdleUnload()
        let language = readingLanguage
        let voice = voiceID
        let atOnce = max(sentencesAtOnce, 1)
        let keys = keys(for: document, voice: voice, language: language)
        preparation = Preparation(done: 0, total: document.sentences.count, wordsToMake: 0)
        preparer = Task { [weak self, store, speaker] in
            let sentences = document.sentences
            let missing = await Task.detached(priority: .userInitiated) {
                sentences.indices.filter { !store.contains(keys[$0], wordCount: sentences[$0].words.count) }
            }.value
            guard let self, !Task.isCancelled else { return }
            guard !missing.isEmpty else {
                self.finishPreparing(at: place, startPlaying: startPlaying)
                return
            }
            self.preparation = Preparation(
                done: sentences.count - missing.count,
                total: sentences.count,
                wordsToMake: missing.reduce(0) { $0 + sentences[$1].words.count }
            )
            do {
                try await self.loadVoice()
                // Longest first, so sentences made together end about together, and the time-left estimate errs
                // long rather than short.
                let order = missing.sorted { sentences[$0].spokenText.count > sentences[$1].spokenText.count }
                let started = ContinuousClock.now
                for batchStart in stride(from: 0, to: order.count, by: atOnce) {
                    try Task.checkCancellation()
                    let batch = Array(order[batchStart..<min(batchStart + atOnce, order.count)])
                    let made = try await speaker.speak(batch.map { sentences[$0] }, voice: voice, language: language)
                    // Saved even if cancelled meanwhile: it's made, and kept for next time.
                    for (index, sentence) in zip(batch, made) {
                        let key = keys[index]
                        await Task.detached(priority: .utility) { store.save(sentence, key: key) }.value
                    }
                    let elapsed = ContinuousClock.now - started
                    self.preparation?.done += batch.count
                    self.preparation?.wordsMade += batch.reduce(0) { $0 + sentences[$1].words.count }
                    self.preparation?.secondsSpent = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                }
            } catch is CancellationError {
                return
            } catch {
                self.failPreparing(error)
                return
            }
            guard !Task.isCancelled else { return }
            self.finishPreparing(at: place, startPlaying: false)
            // The voice isn't needed to read what's made; give its memory back before long.
            self.scheduleIdleUnload()
        }
    }

    private func finishPreparing(at place: ReadingPosition?, startPlaying: Bool) {
        guard let document else { return }
        preparer = nil
        preparation = nil
        stage = .reading
        let place = place.flatMap { document.sentences.indices.contains($0.sentence) ? $0 : nil }
        position = place ?? ReadingPosition(sentence: 0, word: 0)
        playback = .paused
        startLoader()
        if startPlaying { playCurrent() }
    }

    private func failPreparing(_ error: Error) {
        preparer = nil
        preparation = nil
        if case .failed(let message) = voiceState {
            errorMessage = message
        } else {
            errorMessage = "Couldn't make the speech: \(error.localizedDescription)"
        }
        document = nil
        position = nil
        stage = .editing
        scheduleIdleUnload()
    }

    /// Stops making the speech and goes back to the text. What's made so far is kept for next time.
    func cancelPreparing() {
        guard stage == .preparing else { return }
        preparer?.cancel()
        preparer = nil
        loadTask?.cancel()
        preparation = nil
        document = nil
        position = nil
        stage = .editing
        scheduleIdleUnload()
    }

    private func keys(for document: ReadingDocument, voice: String, language: ListenLanguage) -> [String] {
        let identifier = speaker.identifier
        return document.sentences.map {
            SpokenSentenceStore.key(text: $0.voiceText(in: language), engine: identifier, voice: voice, language: language.rawValue)
        }
    }

    // MARK: - Reading

    func togglePlayPause() {
        switch playback {
        case .playing, .waiting: pause()
        case .paused, .stopped: play()
        }
    }

    func pause() {
        guard playback == .playing || playback == .waiting else { return }
        player.pause()
        startingSentence = nil
        playback = .paused
        stopTicker()
        savePosition()
    }

    /// Stops reading (or making the speech) and goes back to editing the text. The place is kept for next time.
    func editText() {
        if stage == .preparing {
            cancelPreparing()
            return
        }
        savePosition()
        player.stop()
        loader?.cancel()
        loader = nil
        stopTicker()
        document = nil
        position = nil
        spoken = [:]
        startingSentence = nil
        playback = .stopped
        stage = .editing
    }

    /// Jumps to the word at a place in the text (a click on it).
    func jump(toLocation location: Int) {
        guard let document, let target = document.position(at: location) else { return }
        jump(to: target)
    }

    func jump(to target: ReadingPosition) {
        guard stage == .reading, let document, document.sentences.indices.contains(target.sentence) else { return }
        position = target
        if playback == .paused || playback == .stopped {
            // Moving while paused shows the new place; Play starts there.
            player.stop()
            playback = .paused
            savePosition()
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

    var canGoBack: Bool { isReading && (position.map { $0.sentence > 0 || $0.word > 0 } ?? false) }
    var canGoForward: Bool {
        guard isReading, let document, let position else { return false }
        return position.sentence + 1 < document.sentences.count
    }

    /// Where the current sentence and word sit in the text, for highlighting.
    var currentSentenceRange: NSRange? {
        guard isReading, let document, let position, document.sentences.indices.contains(position.sentence) else { return nil }
        return document.sentences[position.sentence].range
    }

    var currentWordRange: NSRange? {
        guard isReading, let document, let position else { return nil }
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
        guard stage == .reading, let position else { return }
        startLoader()
        if let sentence = spoken[position.sentence] {
            start(sentence, at: position)
        } else {
            player.stop()
            startingSentence = nil
            playback = .waiting
            stopTicker()
        }
    }

    /// Starts the sentence being waited for once it's loaded.
    private func startIfReady() {
        guard playback == .waiting, let position, startingSentence != position.sentence,
              let sentence = spoken[position.sentence]
        else { return }
        start(sentence, at: position)
    }

    private func start(_ sentence: SpokenSentence, at position: ReadingPosition) {
        let time = sentence.wordTimes.indices.contains(position.word) ? sentence.wordTimes[position.word].start : 0
        let index = position.sentence
        startingSentence = index
        // Until the audio device is ready, which can take a few seconds when it was asleep.
        if playback != .playing { playback = .waiting }
        player.play(sentence, from: time) { [weak self] error in
            guard let self else { return }
            if self.startingSentence == index { self.startingSentence = nil }
            if let error {
                self.fail("Couldn't play the audio: \(error.localizedDescription)")
                return
            }
            self.playback = .playing
            self.startTicker()
        } onFinish: { [weak self] in
            self?.sentenceFinished(index)
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

    /// A new voice or language needs its own speech: it's made (what isn't saved), and reading carries on from the
    /// same place.
    private func voiceOrLanguageChanged() {
        guard document != nil, stage != .editing else { return }
        readingLanguage = language.resolved(for: document?.text ?? text)
        let place = stage == .reading ? position : savedPosition(in: document!)
        savePosition()
        prepare(thenReadFrom: place, startPlaying: false)
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

    // MARK: - Loading what's made

    /// Loads the sentence being read and the few after it from disk, following `position`. A sentence missing from
    /// disk (saved speech cleared while reading) is made again.
    private func startLoader() {
        guard loader == nil, let document else { return }
        let keys = keys(for: document, voice: voiceID, language: readingLanguage)
        let store = store
        loader = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.stage == .reading, let document = self.document, let position = self.position else { return }
                let near = position.sentence..<min(position.sentence + Self.lookahead + 1, document.sentences.count)
                guard let index = near.first(where: { self.spoken[$0] == nil }) else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                let key = keys[index]
                let words = document.sentences[index].words.count
                let loaded = await Task.detached(priority: .userInitiated) { store.load(key) }.value
                guard !Task.isCancelled, self.document == document else { return }
                guard let loaded, loaded.wordTimes.count == words else {
                    self.loader = nil
                    self.prepare(thenReadFrom: self.position, startPlaying: self.playback == .playing || self.playback == .waiting)
                    return
                }
                if self.keepsInMemory(index) { self.spoken[index] = loaded }
                self.startIfReady()
            }
        }
    }

    /// Keeps only sentences near the one playing in memory (an hour of speech is about 350 MB); the rest are on disk.
    private func dropFarSentences() {
        spoken = spoken.filter { keepsInMemory($0.key) }
    }

    private func keepsInMemory(_ index: Int) -> Bool {
        guard let position else { return false }
        return ((position.sentence - 2)...(position.sentence + Self.lookahead + 1)).contains(index)
    }

    // MARK: - Voice models

    /// Loads the downloaded voice and the aligner into memory.
    func loadVoice() async throws {
        if isVoiceLoaded {
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
            // The voice is most of what's loaded, so it takes most of the bar.
            try await speaker.synthesizer.load { fraction, message in report(fraction * 0.85, message) }
            try await speaker.aligner.load { fraction, message in report(0.85 + fraction * 0.15, message) }
        }
        loadTask = task
        voiceState = .loading(progress: 0, message: "Loading the voice…")
        defer { if loadTask == task { loadTask = nil } }
        do {
            try await task.value
            voiceState = .ready
        } catch {
            voiceState = error is CancellationError ? .notLoaded : .failed(Self.describe(error))
            throw error
        }
    }

    // MARK: - Downloading the voice

    /// Downloads the voice's files (only what isn't on disk yet), from the Listen pane or Settings. It carries on
    /// while other panes are open. Loading them into memory waits for Play.
    func downloadVoice() {
        guard !voiceDownload.isDownloading else { return }
        if downloader.isDownloaded() {
            voiceDownload = .downloaded
            return
        }
        errorMessage = nil
        voiceJustDownloaded = false
        let downloader = downloader
        let totalBytes = ListenVoiceModel.approximateDownloadSize
        downloadGeneration += 1
        let generation = downloadGeneration
        voiceDownload = .downloading(VoiceDownloadProgress(fraction: 0, totalBytes: totalBytes))
        downloadTask = Task { [weak self] in
            // Keeps an idle Mac from sleeping partway through a download of several gigabytes.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Downloading the Listen voice"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let estimate = DownloadTimeEstimate()
            do {
                try await downloader.download { fraction in
                    Task { @MainActor in
                        guard let self, self.downloadGeneration == generation,
                              case .downloading(let current) = self.voiceDownload else { return }
                        // Many small steps arrive a second; a tenth of a percent is plenty for the bar.
                        guard fraction - current.fraction >= 0.001 || fraction >= 1 else { return }
                        self.voiceDownload = .downloading(VoiceDownloadProgress(
                            fraction: fraction,
                            totalBytes: totalBytes,
                            secondsLeft: estimate.secondsLeft(at: fraction)
                        ))
                    }
                }
                try Task.checkCancellation()
                guard let self, self.downloadGeneration == generation else { return }
                self.downloadTask = nil
                self.voiceDownload = downloader.isDownloaded()
                    ? .downloaded
                    : .failed(VoiceDownloadFailure(reason: .other, message: "Some of the voice's files are missing after downloading. Try again."))
                if self.voiceDownload == .downloaded {
                    self.voiceJustDownloaded = true
                    // In the background, the Dock icon bounces once to say it's done.
                    if !NSApplication.shared.isActive {
                        NSApplication.shared.requestUserAttention(.informationalRequest)
                    }
                }
            } catch {
                guard let self, self.downloadGeneration == generation else { return }
                self.downloadTask = nil
                if error is CancellationError || Task.isCancelled {
                    self.voiceDownload = downloader.isDownloaded() ? .downloaded : .notDownloaded
                } else {
                    self.voiceDownload = .failed(VoiceDownloadFailure(error))
                }
            }
        }
    }

    /// Stops the download. What's on disk is kept, so downloading again carries on from about where it stopped.
    func cancelVoiceDownload() {
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        if voiceDownload.isDownloading {
            voiceDownload = downloader.isDownloaded() ? .downloaded : .notDownloaded
        }
    }

    /// Checks the disk again, for when the voice's files were changed outside the app.
    func refreshVoiceDownload() {
        guard !voiceDownload.isDownloading else { return }
        let onDisk = downloader.isDownloaded()
        if onDisk {
            voiceDownload = .downloaded
        } else if voiceDownload == .downloaded {
            voiceDownload = .notDownloaded
        }
    }

    /// About how many more bytes the download needs, and how much free space it should leave beside them.
    var downloadSpaceNeeded: Int64 {
        downloader.bytesStillNeeded() + Self.downloadSpaceMargin
    }

    /// Room kept free beside the voice, so downloading it never fills the disk to the brim.
    static let downloadSpaceMargin: Int64 = 500_000_000

    func voiceModelsSize() async -> Int64 {
        let downloader = downloader
        return await Task.detached { downloader.size() }.value
    }

    func deleteVoiceModels() {
        cancelVoiceDownload()
        editText()
        unloadVoice()
        voiceJustDownloaded = false
        do {
            try downloader.removeAll()
        } catch {
            errorMessage = "Couldn't delete the voice models: \(error.localizedDescription)"
        }
        voiceDownload = downloader.isDownloaded() ? .downloaded : .notDownloaded
    }

    func clearSavedSpeech() {
        let store = store
        Task.detached { store.removeAll() }
    }

    func savedSpeechSize() async -> Int64 {
        let store = store
        return await Task.detached { store.size() }.value
    }

    /// Stops for the app to quit. Returns true when the voice models aren't in use; otherwise `whenIdle` is called
    /// once the step being made, or the model being loaded, is done.
    func stopForQuit(whenIdle: @escaping @Sendable () -> Void) -> Bool {
        preparer?.cancel()
        preparer = nil
        loader?.cancel()
        loader = nil
        loadTask?.cancel()
        downloadTask?.cancel()
        downloadTask = nil
        cancelIdleUnload()
        stopTicker()
        player.stop()
        return mlxWork.close(whenIdle: whenIdle)
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
            guard !Task.isCancelled, let self, self.stage != .preparing, self.loadTask == nil else { return }
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
        guard stage == .reading, let document, let position else { return }
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
            return unwrapLines(PDFPageText.withoutHeadersAndFooters(pages).joined(separator: "\n\n"))
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
