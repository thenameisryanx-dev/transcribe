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

final class BackendClient: @unchecked Sendable {
    private enum BackendError: Error, LocalizedError {
        case commandFailed(String)
        case backendScriptNotFound(String)

        var errorDescription: String? {
            switch self {
            case let .commandFailed(message):
                return message
            case let .backendScriptNotFound(message):
                return message
            }
        }
    }

    private let buildTimeRepoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // BackendClient.swift
        .deletingLastPathComponent() // LectureTranscribeNative
        .deletingLastPathComponent() // Sources
    private let activeProcessLock = NSLock()
    private var activeProcess: Process?
    /// The ffmpeg tools of a track save in progress, so it can be cancelled.
    private var activeMedia: MediaTools?
    /// The OpenAI API key; each run's Python process gets it in `OPENAI_API_KEY`.
    let apiKeys: APIKeyStore
    private let openAI: OpenAIClient
    private static let cancelGracePeriodSeconds: Double = 3
    private let fileManager = FileManager.default

    private var executableURL: URL {
        let path = CommandLine.arguments.first ?? ProcessInfo.processInfo.arguments.first ?? ""
        if path.isEmpty {
            return URL(fileURLWithPath: fileManager.currentDirectoryPath)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    private var bundledPythonHomeURL: URL? {
        let bundledHome = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks/Python3.framework/Versions/Current", isDirectory: true)
        let bundledBinary = bundledHome.appendingPathComponent("bin/python3")
        guard fileManager.isExecutableFile(atPath: bundledBinary.path) else {
            return nil
        }
        return bundledHome
    }

    private var bundledPythonProgram: String? {
        guard let bundledHome = bundledPythonHomeURL else { return nil }
        return bundledHome.appendingPathComponent("bin/python3").path
    }

    private var bundledPythonSitePackagesURL: URL? {
        let sitePackages = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/python/site-packages", isDirectory: true)
        guard fileManager.fileExists(atPath: sitePackages.path) else {
            return nil
        }
        return sitePackages
    }

    private var pythonProgram: String {
        let env = ProcessInfo.processInfo.environment
        let override = env["TRANSCRIBE_PYTHON"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return override
        }
        return bundledPythonProgram ?? "python3"
    }

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

    /// The environment each backend process runs with (internal so tests can check the key is passed on).
    var pythonEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        if (env["TRANSCRIBE_WORKDIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            env["TRANSCRIBE_WORKDIR"] = workingDirectoryURL.path
        }
        if let key = apiKeys.currentKey()?.key {
            env["OPENAI_API_KEY"] = key
        }

        let override = env["TRANSCRIBE_PYTHON"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard override.isEmpty, let bundledHome = bundledPythonHomeURL, let bundledProgram = bundledPythonProgram else {
            return env
        }

        env["TRANSCRIBE_PYTHON"] = bundledProgram
        env["PYTHONHOME"] = bundledHome.path
        env["PYTHONNOUSERSITE"] = "1"

        if let sitePackages = bundledPythonSitePackagesURL {
            let existing = env["PYTHONPATH"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            env["PYTHONPATH"] = existing.isEmpty
                ? sitePackages.path
                : "\(sitePackages.path):\(existing)"
        }

        return env
    }

    private func resolveBackendScriptURL() throws -> URL {
        let executableDirectory = executableURL.deletingLastPathComponent()
        let appResourcesDirectory = executableDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let swiftPMBundleDirectory = executableDirectory
            .appendingPathComponent("LectureTranscribeNative_LectureTranscribeNative.bundle", isDirectory: true)

        let cwdCandidate = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("transcribe_backend.py")

        let buildTimeCandidate = buildTimeRepoRoot.appendingPathComponent("transcribe_backend.py")

        let candidates: [URL] = [
            appResourcesDirectory.appendingPathComponent("python/transcribe_backend.py"),
            appResourcesDirectory.appendingPathComponent("transcribe_backend.py"),
            swiftPMBundleDirectory.appendingPathComponent("python/transcribe_backend.py"),
            cwdCandidate,
            buildTimeCandidate,
        ]

        for candidate in candidates {
            if fileManager.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let searched = candidates
            .map(\.path)
            .joined(separator: "\n")
        throw BackendError.backendScriptNotFound(
            """
            Could not locate transcribe backend script.
            Looked in:
            \(searched)
            """
        )
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

    /// The file's audio tracks in order (the backend's `audio-tracks`); empty when ffprobe can't read it.
    func fetchAudioTracks(inputPath: String) async throws -> [AudioTrack] {
        guard fileManager.fileExists(atPath: inputPath) else {
            throw BackendError.commandFailed("Input file not found: \(inputPath)")
        }
        let media = try MediaTools.located()
        return await Task.detached(priority: .userInitiated) { media.audioTracks(URL(fileURLWithPath: inputPath)) }.value
    }

    /// Every track in a video, in file order (the backend's `tracks`).
    func fetchMediaTracks(inputPath: String) async throws -> [MediaTrack] {
        guard fileManager.fileExists(atPath: inputPath) else {
            throw BackendError.commandFailed("Input file not found: \(inputPath)")
        }
        let media = try MediaTools.located()
        return try await Task.detached(priority: .userInitiated) { try media.mediaTracks(URL(fileURLWithPath: inputPath)) }.value
    }

    /// Saves a video with the tracks in `planJSON` (see `TrackPlanEntry`), into the video itself when
    /// `replaceOriginal` is set (the backend's `save-tracks`). It reports `progress` in whole percents, `done` with
    /// the saved file's path, or `error`. Cancel with `cancelActiveRun()`, which leaves the video as it was.
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
        withActiveProcessLock { activeMedia = media }
        defer { withActiveProcessLock { activeMedia = nil } }
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

    /// Runs a transcription in Swift (`TranscriptJob`). `TRANSCRIBE_PYTHON_RUNS=1` sends it to the Python backend
    /// instead, to compare the two.
    func startTranscription(
        _ request: RunRequest,
        onEvent: @escaping @Sendable (BackendStreamEvent) -> Void
    ) async throws {
        let pythonOnly = ProcessInfo.processInfo.environment["TRANSCRIBE_PYTHON_RUNS"] == "1"
        if !pythonOnly {
            try await runInSwift(request, onEvent: onEvent)
        } else {
            try await runStreamCommand(args: request.backendArguments, onEvent: onEvent)
        }
    }

    /// A run in Swift. It reports through the same events as the backend: `error` (and `apiKeyProblem`) when it
    /// fails, `subtitledCopy` when it saves a video with subtitles, `done` with the output's path when it finishes.
    private func runInSwift(_ request: RunRequest, onEvent: @escaping @Sendable (BackendStreamEvent) -> Void) async throws {
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

    /// The backend's `run` arguments for a transcription.
    static func transcriptionArguments(
        inputPath: String,
        outputDirectory: String,
        diarize: Bool,
        subtitles: Bool = false,
        embedSubtitles: Bool = false,
        audioTrack: Int = 0,
        model: String,
        languages: [String] = [],
        context: String = "",
        carryContext: Bool = false,
        chunkSeconds: Int? = nil,
        keywords: [String] = []
    ) -> [String] {
        var args = ["run", "--input", inputPath, "--output", outputDirectory]
        args.append(contentsOf: ["--model", model])
        if !languages.isEmpty {
            args.append(contentsOf: ["--languages", languages.joined(separator: ",")])
        }
        if !context.isEmpty {
            args.append(contentsOf: ["--context", context])
        }
        if !keywords.isEmpty {
            args.append(contentsOf: ["--keywords", keywords.joined(separator: "\n")])
        }
        if carryContext {
            args.append("--carry-context")
        }
        if let chunkSeconds, !diarize {
            args.append(contentsOf: ["--chunk-seconds", String(chunkSeconds)])
        }
        if diarize {
            args.append("--diarize")
        }
        if subtitles {
            args.append("--subtitles")
            // The copy is made from the subtitles, so it's only asked for with them.
            if embedSubtitles {
                args.append("--embed-subtitles")
            }
        }
        if audioTrack > 0 {
            args.append(contentsOf: ["--audio-track", String(audioTrack)])
        }
        return args
    }

    /// Stops a track save, or a run in the Python backend. (A run in Swift stops when its task is cancelled.)
    func cancelActiveRun() {
        withActiveProcessLock {
            activeMedia?.cancel()
            guard let process = activeProcess else { return }
            guard process.isRunning else { return }
            // SIGINT first so the backend can clean up temp files; escalate if it doesn't exit.
            process.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancelGracePeriodSeconds) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    private func runStreamCommand(
        args: [String],
        onEvent: @escaping @Sendable (BackendStreamEvent) -> Void
    ) async throws {
        let backendScriptURL = try resolveBackendScriptURL()
        let pythonProgram = self.pythonProgram

        let streamTask = Task.detached(priority: .userInitiated) { [self] in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            func parseAndDispatch(line: String) {
                guard
                    let data = line.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let kind = object["kind"] as? String
                else {
                    return
                }

                switch kind {
                case "log":
                    onEvent(.log(String(describing: object["payload"] ?? "")))
                case "warning":
                    onEvent(.warning(String(describing: object["payload"] ?? "")))
                case "status":
                    onEvent(.status(String(describing: object["payload"] ?? "")))
                case "progress":
                    let number = (object["payload"] as? NSNumber)?.doubleValue ?? 0
                    onEvent(.progress(number))
                case "done":
                    onEvent(.done(String(describing: object["payload"] ?? "")))
                case "subtitled_copy":
                    onEvent(.subtitledCopy(String(describing: object["payload"] ?? "")))
                case "error":
                    onEvent(.error(String(describing: object["payload"] ?? "")))
                case "error_kind":
                    if (object["payload"] as? String) == "api_key" {
                        onEvent(.apiKeyProblem)
                    }
                default:
                    break
                }
            }

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [pythonProgram, backendScriptURL.path] + args
            process.currentDirectoryURL = backendScriptURL.deletingLastPathComponent()
            process.environment = pythonEnvironment
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            setActiveProcess(process)
            defer {
                setActiveProcess(nil)
            }

            let stderrReader = Task.detached(priority: .utility) {
                String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            }

            let stdout = stdoutPipe.fileHandleForReading
            var textBuffer = ""
            while true {
                if Task.isCancelled {
                    cancelActiveRun()
                    throw CancellationError()
                }

                let data = stdout.availableData
                if data.isEmpty {
                    break
                }
                if let chunk = String(data: data, encoding: .utf8) {
                    textBuffer.append(chunk)
                    while let range = textBuffer.range(of: "\n") {
                        let line = String(textBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        textBuffer.removeSubrange(..<range.upperBound)
                        if !line.isEmpty {
                            parseAndDispatch(line: line)
                        }
                    }
                }
            }

            let trailingLine = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailingLine.isEmpty {
                parseAndDispatch(line: trailingLine)
            }

            process.waitUntilExit()
            let stderr = await stderrReader.value
            if process.terminationStatus != 0 {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Transcription command failed."
                    : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BackendError.commandFailed(message)
            }
        }

        try await withTaskCancellationHandler {
            try await streamTask.value
        } onCancel: {
            streamTask.cancel()
            cancelActiveRun()
        }
    }

    private func setActiveProcess(_ process: Process?) {
        withActiveProcessLock {
            activeProcess = process
        }
    }

    private func withActiveProcessLock<T>(_ body: () -> T) -> T {
        activeProcessLock.lock()
        defer { activeProcessLock.unlock() }
        return body()
    }
}
