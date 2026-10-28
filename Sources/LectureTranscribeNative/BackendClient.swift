import Foundation

enum BackendStreamEvent: Sendable {
    case log(String)
    case warning(String)
    case status(String)
    case progress(Double)
    case done(String)
    /// A copy of the video with the subtitles built in was saved at this path.
    case subtitledCopy(String)
    case error(String)
    /// The run failed because the API key is missing or OpenAI rejected it.
    case apiKeyProblem
}

/// What the app's panes ask of the transcription engine: the API key, a file's tracks, saving a video's tracks,
/// and transcription runs (`TranscriptJob`). Everything runs in this process, with ffmpeg through `MediaTools` and
/// OpenAI through `OpenAIClient`. Long tasks report progress through `BackendStreamEvent`s.
final class BackendClient: @unchecked Sendable {
    private enum BackendError: Error, LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case let .commandFailed(message):
                return message
            }
        }
    }

    private let activeLock = NSLock()
    /// The ffmpeg tools of a track save in progress, so it can be cancelled.
    private var activeMedia: MediaTools?
    /// The OpenAI API key each run uses.
    let apiKeys: APIKeyStore
    private let openAI: OpenAIClient
    private let fileManager = FileManager.default

    /// Scratch space for audio chunks, saved chunk results and converted inputs; keeps them out of the app
    /// bundle. `TRANSCRIBE_WORKDIR` moves it.
    var workingDirectoryURL: URL {
        let override = (ProcessInfo.processInfo.environment["TRANSCRIBE_WORKDIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        return cachesURL.appendingPathComponent("LectureTranscribe", isDirectory: true)
    }

    init(apiKeys: APIKeyStore = APIKeyStore(), openAI: OpenAIClient = OpenAIClient()) {
        self.apiKeys = apiKeys
        self.openAI = openAI
    }

    /// Where the API key comes from, like "loaded from system keychain", or "required" when there is none.
    /// With `verify`, also asks OpenAI whether the key works; only a definite rejection changes the status,
    /// so being offline doesn't flag a good key.
    func fetchAPIKeyStatus(verify: Bool = false) async throws -> String {
        guard let current = apiKeys.currentKey() else { return APIKeyStore.Status.required }
        if verify, await openAI.checkKey(current.key) == .rejected {
            return APIKeyStore.Status.rejected
        }
        return current.status
    }

    /// Checks `key` with OpenAI, then uses it from now on (and saves it in the keychain when asked).
    func setAPIKey(_ key: String, saveToKeychain: Bool) async throws -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIKeyStore.isValid(key) else {
            throw BackendError.commandFailed("Invalid API key format. It should start with 'sk-'.")
        }
        switch await openAI.checkKey(key) {
        case .rejected:
            throw BackendError.commandFailed("OpenAI didn't accept this key. Copy it again from platform.openai.com/api-keys.")
        case .unreachable:
            throw BackendError.commandFailed("Couldn't reach OpenAI to check this key. Check your internet connection, then try again.")
        case .ok:
            return try apiKeys.setKey(key, save: saveToKeychain)
        }
    }

    /// The file's audio tracks in order ; empty when ffprobe can't read it.
    func fetchAudioTracks(inputPath: String) async throws -> [AudioTrack] {
        guard fileManager.fileExists(atPath: inputPath) else {
            throw BackendError.commandFailed("Input file not found: \(inputPath)")
        }
        let media = try MediaTools.located()
        return await Task.detached(priority: .userInitiated) { media.audioTracks(URL(fileURLWithPath: inputPath)) }.value
    }

    /// Every track in a video, in file order.
    func fetchMediaTracks(inputPath: String) async throws -> [MediaTrack] {
        guard fileManager.fileExists(atPath: inputPath) else {
            throw BackendError.commandFailed("Input file not found: \(inputPath)")
        }
        let media = try MediaTools.located()
        return try await Task.detached(priority: .userInitiated) { try media.mediaTracks(URL(fileURLWithPath: inputPath)) }.value
    }

    /// Saves a video with the tracks in `planJSON` (see `TrackPlanEntry`), into the video itself when
    /// `replaceOriginal` is set. It reports `progress` in whole percents, `done` with the saved file's path, or
    /// `error`. Cancel with `cancelActiveRun()`, which leaves the video as it was.
    func saveTracks(
        inputPath: String,
        outputPath: String,
        planJSON: String,
        replaceOriginal: Bool = false,
        onEvent: @escaping @Sendable (BackendStreamEvent) -> Void
    ) async throws {
        func fail(_ message: String) throws -> Never {
            onEvent(.error(message))
            throw BackendError.commandFailed(message)
        }
        let plan: [TrackPlanEntry]
        do {
            plan = try TrackPlanEntry.parse(planJSON)
        } catch let error as MediaTools.Failure {
            try fail(error.localizedDescription)
        } catch {
            try fail("Invalid track list: \(error.localizedDescription)")
        }
        guard fileManager.fileExists(atPath: inputPath) else {
            try fail("Input file not found: \(inputPath)")
        }
        let media: MediaTools
        do {
            media = try MediaTools.located()
        } catch {
            try fail(error.localizedDescription)
        }

        onEvent(.status("Saving..."))
        let video = URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath)
        let output = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
        withActiveLock { activeMedia = media }
        defer { withActiveLock { activeMedia = nil } }
        do {
            try await Task.detached(priority: .userInitiated) {
                var reported = -1
                try media.saveEditedTracks(video: video, output: output, plan: plan, replaceOriginal: replaceOriginal) { fraction in
                    let percent = Int(fraction * 100)
                    if percent > reported {
                        reported = percent
                        onEvent(.progress(Double(percent)))
                    }
                }
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try fail(error.localizedDescription)
        }
        onEvent(.done(output.resolvingSymlinksInPath().path))
    }

    /// Runs a transcription (`TranscriptJob`). It reports `error` (and `apiKeyProblem`) when it fails,
    /// `subtitledCopy` when it saves a video with subtitles, and `done` with the output's path when it finishes.
    /// Cancel the task running it to stop it.
    func startTranscription(_ request: RunRequest, onEvent: @escaping @Sendable (BackendStreamEvent) -> Void) async throws {
        func fail(_ message: String, apiKeyProblem: Bool = false) throws -> Never {
            if apiKeyProblem { onEvent(.apiKeyProblem) }
            onEvent(.error(message))
            throw BackendError.commandFailed(message)
        }
        guard fileManager.fileExists(atPath: request.inputPath) else {
            try fail("Input file not found: \(request.inputPath)")
        }
        guard let key = apiKeys.currentKey()?.key else {
            try fail("Add your OpenAI API key to start transcribing.", apiKeyProblem: true)
        }
        let media: MediaTools
        do {
            media = try MediaTools.located()
        } catch {
            try fail(error.localizedDescription)
        }
        let job = TranscriptJob(
            request: request,
            apiKey: key,
            openAI: openAI,
            media: media,
            workDirectory: workingDirectoryURL,
            maxParallel: TranscriptJob.maxParallel(environment: ProcessInfo.processInfo.environment),
            emit: onEvent
        )
        do {
            let output = try await job.run()
            onEvent(.done(output.resolvingSymlinksInPath().path))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let described = TranscriptJob.describe(error)
            try fail(described.message, apiKeyProblem: described.isAPIKeyProblem)
        }
    }

    /// Stops a track save in progress, leaving the video as it was. (A transcription stops when its task is
    /// cancelled.)
    func cancelActiveRun() {
        withActiveLock { activeMedia?.cancel() }
    }

    private func withActiveLock<T>(_ body: () -> T) -> T {
        activeLock.lock()
        defer { activeLock.unlock() }
        return body()
    }
}
