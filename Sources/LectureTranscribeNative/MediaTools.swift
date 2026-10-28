import Foundation

/// ffmpeg and ffprobe, run from Swift: reading a recording, finding pauses, cutting it into chunks, and saving a
/// copy of a video with subtitles.
/// Ported from the Python backend (`lecture_transcribe.py`), with the same commands, so the chunks come out
/// byte for byte the same.
final class MediaTools: @unchecked Sendable {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // Chunk boundaries move back to the quietest moment in the stretch before each cut, so a sentence isn't
    // sliced in half.
    static let splitSearchSeconds = 60.0
    static let splitFrameSeconds = 0.1
    static let splitPauseFrames = 5
    /// Share of the split's progress spent finding pauses; ffmpeg writing the chunks gets the rest.
    static let splitPlanShare = 0.1
    /// Sources with more channels are always re-encoded, never copied (surround keeps dialogue in the center).
    static let maxCopyChannels = 2
    /// The API rejects uploads over 25 MB; copied chunks bigger than this are re-encoded instead.
    static let maxUploadBytes = 24 * 1024 * 1024
    static let audioBitrate = "128k"
    static let audioChannels = "1"
    static let processTimeout: TimeInterval = 30 * 60

    /// Containers a subtitled copy of a video can be saved in (by extension), with the subtitle format each takes.
    /// The .srt is added without re-encoding, so only containers that hold text subtitles qualify. The subtitles
    /// are the copy's only subtitle track: QuickTime showed none at all for an episode that also carried its 32
    /// original subtitle tracks.
    static let embedSubtitleCodecs = ["mp4": "mov_text", "m4v": "mov_text", "mov": "mov_text", "mkv": "srt"]
    /// The sample format ffmpeg writes for mov_text subtitles. In a .mov it labels them "text" (old QuickTime text)
    /// unless told otherwise, and Apple's players then list the track but show nothing.
    static let movTextTag = "tx3g"
    /// MP4 and QuickTime files need three-letter ISO 639-2 language codes (ffmpeg silently drops "en"). These cover
    /// the languages the app offers; Matroska asks for the bibliographic form where it differs.
    static let iso639_2: [String: String] = [
        "ar": "ara", "cs": "ces", "da": "dan", "de": "deu", "el": "ell", "en": "eng", "es": "spa", "fa": "fas",
        "fi": "fin", "fr": "fra", "he": "heb", "hi": "hin", "hu": "hun", "id": "ind", "it": "ita", "ja": "jpn",
        "ko": "kor", "ms": "msa", "nl": "nld", "no": "nor", "pl": "pol", "pt": "por", "ro": "ron", "ru": "rus",
        "sv": "swe", "th": "tha", "tl": "tgl", "tr": "tur", "uk": "ukr", "ur": "urd", "vi": "vie", "zh": "zho",
    ]
    static let iso639_2Bibliographic: [String: String] = [
        "ces": "cze", "deu": "ger", "ell": "gre", "fas": "per", "fra": "fre", "msa": "may", "nld": "dut",
        "ron": "rum", "zho": "chi",
    ]

    let ffmpeg: URL
    let ffprobe: URL
    private let lock = NSLock()
    private var running: Process?
    private var cancelled = false

    init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// The pinned ffmpeg build: `FFMPEG_BIN`/`FFPROBE_BIN` (source runs and tests), the copy bundled in the app,
    /// or the repository's vendor/ffmpeg. Never another ffmpeg on the system.
    static func located(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
    ) throws -> MediaTools {
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/python/ffmpeg_bin")
        var architecture = utsname()
        uname(&architecture)
        let machine = withUnsafeBytes(of: &architecture.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let vendor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/ffmpeg/\(machine)")

        func find(_ name: String, variable: String) throws -> URL {
            var candidates: [URL] = []
            if let path = environment[variable]?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
                candidates.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
            candidates += [bundled.appendingPathComponent(name), vendor.appendingPathComponent(name)]
            guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw Failure("\(name) not found. Reinstall the latest app build, which includes it.")
            }
            return found
        }
        return MediaTools(ffmpeg: try find("ffmpeg", variable: "FFMPEG_BIN"), ffprobe: try find("ffprobe", variable: "FFPROBE_BIN"))
    }

    /// Stops the ffmpeg or ffprobe running now, and any started later.
    func cancel() {
        lock.withLock {
            cancelled = true
            running?.terminate()
        }
    }

    // MARK: - Running the tools

    /// Runs a tool to the end; `onLine` gets each line of its standard output as it comes.
    @discardableResult
    func run(
        _ tool: URL,
        _ arguments: [String],
        timeout: TimeInterval = MediaTools.processTimeout,
        captureErrors: Bool = true,
        onLine: ((String) -> Void)? = nil
    ) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = captureErrors ? errors : FileHandle.nullDevice
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            running = process
        }
        defer { lock.withLock { running = nil } }

        let timedOut = Flag()
        let timer = DispatchWorkItem {
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }

        let errorData = DataBox()
        let errorReader = DispatchGroup()
        if captureErrors {
            errorReader.enter()
            DispatchQueue.global().async {
                errorData.value = errors.fileHandleForReading.readDataToEndOfFile()
                errorReader.leave()
            }
        }
        var collected = Data()
        var pending = Data()
        let handle = output.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            collected.append(chunk)
            guard let onLine else { continue }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        process.waitUntilExit()
        errorReader.wait()
        if lock.withLock({ cancelled }) { throw CancellationError() }
        if timedOut.isSet {
            throw Failure("\(tool.lastPathComponent) took longer than \(Int(timeout / 60)) minutes and was stopped.")
        }
        return (process.terminationStatus, String(decoding: collected, as: UTF8.self), String(decoding: errorData.value, as: UTF8.self))
    }

    private func probe(_ arguments: [String]) -> String? {
        guard let result = try? run(ffprobe, ["-v", "error"] + arguments, timeout: 30), result.status == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reading a recording

    /// The recording's length in seconds, or -1 when ffprobe can't tell.
    func duration(_ url: URL) -> Double {
        probe(["-show_entries", "format=duration", "-of", "default=nk=1:nw=1", url.path]).flatMap(Double.init) ?? -1
    }

    /// The recording's audio tracks in order; empty when ffprobe can't read it.
    func audioTracks(_ url: URL) -> [AudioTrack] {
        guard let json = probe([
            "-select_streams", "a",
            "-show_entries", "stream=codec_name,channels:stream_tags=language,title:stream_disposition=default",
            "-of", "json", url.path,
        ]), let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        let streams = object["streams"] as? [[String: Any]] ?? []
        return streams.enumerated().compactMap { index, stream in
            let tags = stream["tags"] as? [String: Any] ?? [:]
            let language = ((tags["language"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            var entry: [String: Any] = [
                "index": index,
                // "und" is how containers mark an unknown language.
                "language": language == "und" ? "" : language,
                "title": ((tags["title"] as? String) ?? "").trimmingCharacters(in: .whitespaces),
                "codec": stream["codec_name"] as? String ?? "",
                "default": ((stream["disposition"] as? [String: Any])?["default"] as? Int ?? 0) != 0,
            ]
            if let channels = stream["channels"] as? Int {
                entry["channels"] = channels
            }
            guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(AudioTrack.self, from: data)
        }
    }

    func codecName(_ url: URL, audioTrack: Int = 0) -> String? {
        probe(["-select_streams", "a:\(audioTrack)", "-show_entries", "stream=codec_name", "-of", "default=nk=1:nw=1", url.path])
            .map { $0.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
    }

    func channelCount(_ url: URL, audioTrack: Int = 0) -> Int? {
        probe(["-select_streams", "a:\(audioTrack)", "-show_entries", "stream=channels", "-of", "default=nk=1:nw=1", url.path])
            .flatMap { $0.split(separator: "\n").first.flatMap { Int($0) } }
    }

    /// Codecs of the file's video tracks, leaving out cover art (empty if ffprobe can't tell).
    func videoCodecNames(_ url: URL) -> [String] {
        let output = probe(["-select_streams", "V", "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path]) ?? ""
        // Side data (e.g. a Dolby Vision record) adds empty fields after the codec: "hevc,".
        return output.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.split(separator: ",", omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces).lowercased() }
    }

    // MARK: - Finding pauses

    /// The time of the quietest ~0.5s inside [windowStart, windowStart + windowSeconds], or nil.
    func quietestPoint(_ url: URL, windowStart: Double, windowSeconds: Double, audioTrack: Int = 0) -> Double? {
        let sampleRate = 16000
        let frameSamples = Int(Double(sampleRate) * Self.splitFrameSeconds)
        guard let result = try? run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-ss", String(format: "%.3f", windowStart),
            "-t", String(format: "%.3f", windowSeconds),
            "-i", url.path, "-vn", "-map", "0:a:\(audioTrack)",
            "-af", "aresample=\(sampleRate),asetnsamples=n=\(frameSamples):p=0,astats=metadata=1:reset=1,"
                + "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-",
            "-f", "null", "-",
        ], timeout: 120), result.status == 0 else { return nil }

        let prefix = "lavfi.astats.Overall.RMS_level="
        let levels: [Double] = result.output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix(prefix) else { return nil }
            let level = Double(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)) ?? -200
            // Digital silence reports -inf.
            return level > -200 ? level : -200
        }
        let frames = Self.splitPauseFrames
        guard levels.count >= frames else { return nil }
        var bestIndex = 0
        var bestLevel = Double.infinity
        for i in 0...(levels.count - frames) {
            let level = levels[i..<(i + frames)].reduce(0, +) / Double(frames)
            // `<=` keeps the latest of equally quiet spots, so chunks stay close to their nominal length.
            if level <= bestLevel {
                bestLevel = level
                bestIndex = i
            }
        }
        return windowStart + (Double(bestIndex) + Double(frames) / 2) * Self.splitFrameSeconds
    }

    /// Cut times for chunks of at most `chunkSeconds`, each moved back to the quietest moment before it.
    /// Empty when the audio fits in one chunk or its length is unknown. `onProgress` gets the share planned.
    func chunkCuts(_ url: URL, chunkSeconds: Int, audioTrack: Int = 0, onProgress: ((Double) -> Void)? = nil) throws -> [Double] {
        let total = duration(url)
        let chunk = Double(chunkSeconds)
        guard total > chunk else { return [] }
        let search = min(Self.splitSearchSeconds, chunk / 4)
        var cuts: [Double] = []
        var previous = 0.0
        while total - previous > chunk {
            try Task.checkCancellation()
            let target = previous + chunk
            let windowStart = target - search
            var cut = quietestPoint(url, windowStart: windowStart, windowSeconds: search, audioTrack: audioTrack) ?? target
            if !(windowStart <= cut && cut <= target) { cut = target }
            cuts.append(cut)
            previous = cut
            onProgress?(previous / total)
        }
        return cuts
    }

    // MARK: - Splitting

    /// Reads the lines of `-progress pipe:1`, passing the share of the input processed so far.
    private static func progressReader(totalSeconds: Double, _ onProgress: @escaping (Double) -> Void) -> (String) -> Void {
        { line in
            // out_time_us is the position reached in the input; it keeps counting across segments.
            guard totalSeconds > 0, line.hasPrefix("out_time_us="), let micros = Int(line.dropFirst("out_time_us=".count)) else { return }
            onProgress(min(max(Double(micros) / 1_000_000 / totalSeconds, 0), 1))
        }
    }

    /// Runs an ffmpeg command that writes `-progress pipe:1`, passing the share of the input processed so far.
    private func runWithProgress(_ arguments: [String], totalSeconds: Double, quiet: Bool, onProgress: @escaping (Double) -> Void) throws {
        let result = try run(ffmpeg, arguments, captureErrors: !quiet, onLine: Self.progressReader(totalSeconds: totalSeconds, onProgress))
        guard result.status == 0 else {
            let detail = result.errors.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").suffix(3).joined(separator: " ")
            throw Failure("ffmpeg failed (exit \(result.status))\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }

    private func chunkFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("part_") && $0.hasSuffix(".m4a") }.sorted().map { directory.appendingPathComponent($0) }
    }

    private func removeChunkFiles(in directory: URL) {
        chunkFiles(in: directory).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Splits `audioTrack` of `url` into `part_NNN.m4a` files of at most `chunkSeconds`, cut at pauses.
    /// Mono or stereo AAC is copied without re-encoding when every piece fits the upload limit; anything else,
    /// including surround audio, is re-encoded to mono AAC. `onProgress` gets how far along the split is.
    func split(_ url: URL, into directory: URL, chunkSeconds: Int, audioTrack: Int = 0, onProgress: ((Double) -> Void)? = nil) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var reported = 0.0
        func report(_ fraction: Double) {
            // Never move backwards, e.g. when a finished copy is rejected and the audio is re-encoded.
            if fraction > reported {
                reported = fraction
                onProgress?(fraction)
            }
        }
        func reportWriting(_ fraction: Double) { report(Self.splitPlanShare + (1 - Self.splitPlanShare) * fraction) }

        let total = duration(url)
        let cuts = try chunkCuts(url, chunkSeconds: chunkSeconds, audioTrack: audioTrack) { report(Self.splitPlanShare * $0) }
        report(Self.splitPlanShare)
        let segmentArguments = cuts.isEmpty
            ? ["-segment_time", String(chunkSeconds)]
            : ["-segment_times", cuts.map { String(format: "%.3f", $0) }.joined(separator: ",")]
        let output = directory.appendingPathComponent("part_%03d.m4a").path
        removeChunkFiles(in: directory)

        let channels = channelCount(url, audioTrack: audioTrack)
        let codec = codecName(url, audioTrack: audioTrack)
        // Only AAC can be copied into .m4a; MP3 would copy but then be rejected, and WAV wouldn't copy at all.
        if (channels == nil || channels! <= Self.maxCopyChannels) && (codec == nil || codec == "aac") {
            let copied: Bool
            do {
                // A failed copy is handled by re-encoding below, so its error output is left out of the log.
                try runWithProgress(
                    ["-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-nostats",
                     "-i", url.path, "-vn", "-f", "segment"] + segmentArguments
                        + ["-reset_timestamps", "1", "-map", "0:a:\(audioTrack)", "-c:a", "copy", output],
                    totalSeconds: total, quiet: true, onProgress: reportWriting
                )
                copied = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                copied = false
            }
            let parts = chunkFiles(in: directory)
            // A copy that stopped partway leaves only the first chunks, which would silently drop the rest.
            if copied, !parts.isEmpty,
               parts.allSatisfy({ ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= Self.maxUploadBytes }),
               parts.prefix(2).allSatisfy({ codecName($0) == "aac" })
            {
                return parts
            }
        }

        removeChunkFiles(in: directory)
        try runWithProgress(
            ["-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-nostats",
             "-i", url.path, "-vn", "-f", "segment"] + segmentArguments
                + ["-reset_timestamps", "1", "-map", "0:a:\(audioTrack)", "-c:a", "aac",
                   "-ac", Self.audioChannels, "-b:a", Self.audioBitrate, output],
            totalSeconds: total, quiet: false, onProgress: reportWriting
        )
        let parts = chunkFiles(in: directory)
        guard !parts.isEmpty else { throw Failure("No chunks created. Is the input a valid audio file?") }
        return parts
    }

    /// Copies `audioTrack` of a .qta file (a QuickTime container) to `output`, an .m4a holding only that track
    /// (`convert_qta_to_m4a_copy`). The audio is copied as is to avoid quality loss, or re-encoded to AAC when it
    /// can't be copied.
    func convertQTA(_ url: URL, to output: URL, audioTrack: Int = 0) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        let input = ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "mov", "-i", url.path, "-vn", "-map", "0:a:\(audioTrack)"]
        let copied: Bool
        do {
            copied = try run(ffmpeg, input + ["-c:a", "copy", output.path]).status == 0
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            copied = false
        }
        if !copied {
            try? FileManager.default.removeItem(at: output)
            let result: (status: Int32, output: String, errors: String)
            do {
                result = try run(ffmpeg, input + ["-c:a", "aac", "-b:a", Self.audioBitrate, output.path])
            } catch is Failure {
                try? FileManager.default.removeItem(at: output)
                // `run` stops a tool that takes too long with a Failure.
                throw Failure("Timed out converting .qta to .m4a. Please verify the file opens normally in QuickTime.")
            }
            guard result.status == 0 else {
                try? FileManager.default.removeItem(at: output)
                let detail = result.errors.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").suffix(3).joined(separator: " ")
                throw Failure("Failed to convert .qta to .m4a\(detail.isEmpty ? "." : ": \(detail)")")
            }
        }
        guard ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            throw Failure("Failed to convert .qta to .m4a.")
        }
    }

    /// A re-encoded copy of a chunk OpenAI rejected as unreadable (`repair_audio_for_api`).
    func repairedForAPI(_ url: URL) throws -> URL {
        let repaired = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_repaired.m4a")
        try? FileManager.default.removeItem(at: repaired)
        let result = try run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", url.path, "-vn",
                                      "-c:a", "aac", "-ac", Self.audioChannels, "-b:a", Self.audioBitrate, repaired.path])
        let size = (try? repaired.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard result.status == 0, size > 0 else {
            throw Failure("Could not repair audio for transcription: \(result.errors.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return repaired
    }

    // MARK: - Subtitled copies

    /// Three-letter language tag for a subtitle track in this container, or nil if the code isn't known.
    static func subtitleTrackLanguage(_ code: String?, containerExtension: String) -> String? {
        let code = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isThreeLetters = code.unicodeScalars.count == 3 && code.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        guard var tag = iso639_2[code] ?? (isThreeLetters ? code : nil) else { return nil }
        if containerExtension.lowercased() == "mkv" {
            tag = iso639_2Bibliographic[tag] ?? tag
        }
        return tag
    }

    /// Writes a copy of `video`, in the same container, with `srt` as its only subtitle track, shown by default
    /// (`embed_subtitles_copy`). Video and every audio track are copied without re-encoding; `audioTrack` (the one
    /// the subtitles were made from) becomes the default audio. `output`'s extension must be one of
    /// `embedSubtitleCodecs` and the file must not exist yet; it is never overwritten. `language` is a
    /// spoken-language code ("en") that tags the subtitles when known. A failed or cancelled copy is removed.
    func embedSubtitlesCopy(
        video: URL,
        srt: URL,
        output: URL,
        language: String?,
        audioTrack: Int = 0,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) throws {
        let container = output.pathExtension.lowercased()
        guard let codec = Self.embedSubtitleCodecs[container] else {
            throw Failure("Subtitles can't be built into .\(container) videos.")
        }
        var trackOptions = ["-c:s", codec, "-disposition:s:0", "default"]
        if container != "mkv" {
            trackOptions += ["-tag:s:0", Self.movTextTag]
            // QuickTime only plays HEVC tagged hvc1 in these containers; ffmpeg's default tag for it is hev1.
            for (index, codec) in videoCodecNames(video).enumerated() where codec == "hevc" {
                trackOptions += ["-tag:v:\(index)", "hvc1"]
            }
        }
        // Play the language the subtitles were made from; the others stay selectable.
        let audioCount = audioTracks(video).count
        if audioCount > 1 && (0..<audioCount).contains(audioTrack) {
            for index in 0..<audioCount {
                trackOptions += ["-disposition:a:\(index)", index == audioTrack ? "default" : "-default"]
            }
        }
        if let tag = Self.subtitleTrackLanguage(language, containerExtension: container) {
            trackOptions += ["-metadata:s:s:0", "language=\(tag)"]
        }

        let arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-nostats",
            // Refuse to overwrite, in case a file appeared at `output` after it was chosen.
            "-n",
            "-i", video.path,
            "-i", srt.path,
            // Video (not cover art) and audio from the original, then the subtitles. The original's own subtitle
            // and data tracks are left out (see embedSubtitleCodecs); chapters are kept.
            "-map", "0:V",
            "-map", "0:a?",
            "-map", "1:0",
            "-c", "copy",
        ] + trackOptions + [output.path]
        let status: Int32
        do {
            status = try run(ffmpeg, arguments, onLine: Self.progressReader(totalSeconds: duration(video), onProgress)).status
        } catch {
            try? FileManager.default.removeItem(at: output)
            // `run` stops a tool that takes too long with a Failure.
            if error is Failure { throw Failure("Timed out saving the copy of the video with subtitles.") }
            throw error
        }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw Failure("ffmpeg couldn't copy this video's tracks into .\(output.pathExtension) (exit code \(status)).")
        }
        guard ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            throw Failure("ffmpeg didn't write the copy of the video with subtitles.")
        }
    }

    /// Removes a chunk folder's `part_*.m4a` files, then the folder if that left it empty (`cleanup_dir`).
    func removeChunks(in directory: URL) {
        removeChunkFiles(in: directory)
        rmdir(directory.path)
    }
}

/// A flag one thread sets and another reads.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Data one thread writes before another reads it (ordered by a DispatchGroup).
private final class DataBox: @unchecked Sendable {
    var value = Data()
}
