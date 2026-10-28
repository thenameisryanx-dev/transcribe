import Foundation

/// One track the Tracks pane saves: a track of the video or a subtitle
/// file to add, with the language, title and flags it's saved with.
struct TrackPlanEntry: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// A track of the video, by its index among all of the file's tracks (see `MediaTools.mediaTracks`).
        case original(index: Int)
        /// A subtitle file to add.
        case file(path: String)
    }

    let kind: String
    let source: Source
    let language: String
    let title: String
    let isDefault: Bool
    let isForced: Bool

    /// The plan as the Tracks pane writes it (`TrackEditorModel.planJSON`).
    static func parse(_ json: String) throws -> [TrackPlanEntry] {
        guard let entries = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw MediaTools.Failure("Invalid track list: expected a list")
        }
        return entries.map { entry in
            let source: Source
            if let path = entry["file"] as? String {
                source = .file(path: path)
            } else {
                source = .original(index: (entry["index"] as? Int) ?? -1)
            }
            return TrackPlanEntry(
                kind: entry["kind"] as? String ?? "",
                source: source,
                language: entry["language"] as? String ?? "",
                title: entry["title"] as? String ?? "",
                isDefault: entry["default"] as? Bool ?? false,
                isForced: entry["forced"] as? Bool ?? false
            )
        }
    }
}

/// Reading and saving a video's tracks for the Tracks pane, with ffprobe and ffmpeg.
extension MediaTools {
    /// Subtitle codecs stored as text. Others (PGS, VobSub) are pictures, which only some containers hold.
    static let textSubtitleCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"]
    /// Subtitle files that can be added to a video in the track editor.
    static let addableSubtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]
    /// ffprobe doesn't read the title ffmpeg writes for an .mp4/.mov track, so titles are also saved as the track's
    /// handler name. Names that tools give every handler on their own ("SoundHandler", "Core Media Audio") aren't
    /// titles.
    static let genericHandlerName = try! NSRegularExpression(
        pattern: #"handler|^(core media|apple|gpac|l-smash|mainconcept|iso ?media|bento4)\b"#,
        options: [.caseInsensitive]
    )
    static let movDefaultHandlerNames = ["audio": "SoundHandler", "subtitle": "SubtitleHandler"]
    /// Handler types of .mp4/.mov subtitle tracks. Older versions of the app gave subtitles added to a .mov "text",
    /// the type of chapter tracks too; those are never enabled, so clearing their flag changes nothing.
    static let movSubtitleHandlerTypes: Set<Data> = [Data("sbtl".utf8), Data("subt".utf8), Data("text".utf8)]

    /// Every track in the file, in order. `index` is the stream's position in the whole file (ffmpeg's `0:N`);
    /// cover art counts as an attachment.
    func mediaTracks(_ url: URL) throws -> [MediaTrack] {
        let failure = Failure("Couldn't read the tracks in \(url.lastPathComponent). Is it a video file?")
        let result: (status: Int32, output: String, errors: String)
        do {
            result = try run(ffprobe, [
                "-v", "error",
                "-show_entries",
                "stream=index,codec_type,codec_name,codec_tag_string,channels"
                    + ":stream_tags=language,title,handler_name:stream_disposition=default,forced,attached_pic",
                "-of", "json",
                url.path,
            ], timeout: 30)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure
        }
        guard result.status == 0,
              let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        else { throw failure }

        var tracks: [MediaTrack] = []
        for stream in object["streams"] as? [[String: Any]] ?? [] {
            let tags = stream["tags"] as? [String: Any] ?? [:]
            let disposition = stream["disposition"] as? [String: Any] ?? [:]
            func flag(_ name: String) -> Bool { ((disposition[name] as? Int) ?? 0) != 0 }
            func tag(_ name: String) -> String { ((tags[name] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            var kind = stream["codec_type"] as? String ?? "data"
            if kind == "video" && flag("attached_pic") {
                kind = "attachment"
            } else if !["video", "audio", "subtitle", "attachment"].contains(kind) {
                kind = "data"
            }
            let codec = (stream["codec_name"] as? String ?? "").lowercased()
            let language = tag("language").lowercased()
            var title = tag("title")
            let handlerName = tag("handler_name")
            let handlerRange = NSRange(handlerName.startIndex..., in: handlerName)
            if title.isEmpty && Self.genericHandlerName.firstMatch(in: handlerName, range: handlerRange) == nil {
                title = handlerName
            }
            tracks.append(MediaTrack(
                index: stream["index"] as? Int ?? tracks.count,
                kind: kind,
                codec: codec,
                // "und" is how containers mark an unknown language.
                language: language == "und" ? "" : language,
                title: title,
                default: flag("default"),
                forced: flag("forced"),
                channels: stream["channels"] as? Int,
                text: kind == "subtitle" && Self.textSubtitleCodecs.contains(codec),
                codecTag: stream["codec_tag_string"] as? String ?? ""
            ))
        }
        return tracks
    }

    /// The file the way the system names it, with symbolic links followed, so two paths to the same file compare
    /// equal even when it doesn't exist yet.
    private static func resolved(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Writes `video` with the audio and subtitle tracks in `plan`, in that order, without re-encoding. Tracks of
    /// the original that aren't in the plan are left out. Video, cover art, fonts and chapters are kept. `output`
    /// must have the video's extension. It is the video itself only with `replaceOriginal` (Save); otherwise it
    /// must be another file (Save As). Either way the new file is written under a temporary name next to `output`
    /// and moved into place only once complete, so a failed or cancelled save leaves `output` as it was and nothing
    /// else behind. `onProgress` gets how far along it is (0 to 1).
    func saveEditedTracks(
        video: URL,
        output: URL,
        plan: [TrackPlanEntry],
        replaceOriginal: Bool = false,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) throws {
        let container = video.pathExtension.lowercased()
        guard Self.embedSubtitleCodecs[container] != nil else {
            let kinds = Self.embedSubtitleCodecs.keys.sorted().map { ".\($0)" }.joined(separator: ", ")
            throw Failure("Tracks can only be edited in \(kinds) videos.")
        }
        guard output.pathExtension.lowercased() == container else {
            throw Failure("Save the video as a .\(container) file, the same format as the original.")
        }
        let isOriginal = Self.resolved(output) == Self.resolved(video)
        if isOriginal && !replaceOriginal {
            throw Failure("Saving under the video's own name replaces it. Use Save to do that, or choose another name.")
        }
        if replaceOriginal && !isOriginal {
            throw Failure("Save replaces the video itself, so it can't be given another name.")
        }
        // The new file sits next to the destination until it's complete, so there must be room for both.
        let size = (try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0
        let needed = Int(Double(size) * 1.02) + 50 * 1024 * 1024
        let directory = output.deletingLastPathComponent()
        if let free = (try? FileManager.default.attributesOfFileSystem(forPath: directory.path))?[.systemFreeSize] as? Int, free < needed {
            throw Failure(String(
                format: "Not enough disk space to save: it needs about %.1f GB free while saving, and there's %.1f GB.",
                Double(needed) / 1e9, Double(free) / 1e9
            ))
        }

        let originals = try mediaTracks(video)
        let isMOV = container != "mkv"
        var inputs = ["-i", video.path]
        var maps: [String] = []
        var options: [String] = []
        // Video, cover art and fonts are kept as they are; data tracks (timecodes, iPhone metadata) are left out.
        let pictures = originals.filter { $0.kind == "video" || $0.kind == "attachment" }
        for track in pictures {
            maps += ["-map", "0:\(track.index)"]
        }
        if isMOV {
            // QuickTime only plays HEVC tagged hvc1 in these containers; ffmpeg's default tag for it is hev1.
            for (n, track) in pictures.enumerated() where track.codec == "hevc" {
                options += ["-tag:v:\(n)", "hvc1"]
            }
        }

        var counts = ["audio": 0, "subtitle": 0]
        var extraInputs = 0
        for entry in plan {
            guard let n = counts[entry.kind] else { throw Failure("Unknown track kind: '\(entry.kind)'.") }
            switch entry.source {
            case let .file(path):
                let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard entry.kind == "subtitle", Self.addableSubtitleExtensions.contains(file.pathExtension.lowercased()) else {
                    throw Failure("\(file.lastPathComponent) isn't a subtitle file the app can add (.srt, .ass, .ssa or .vtt).")
                }
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw Failure("Subtitle file not found: \(file.path)")
                }
                extraInputs += 1
                inputs += ["-i", file.path]
                maps += ["-map", "\(extraInputs):0"]
                if isMOV {
                    options += ["-c:s:\(n)", "mov_text", "-tag:s:\(n)", Self.movTextTag]
                }
            case let .original(index):
                guard let source = originals.first(where: { $0.index == index }), source.kind == entry.kind else {
                    throw Failure("The video has no \(entry.kind) track #\(index).")
                }
                maps += ["-map", "0:\(source.index)"]
                if isMOV && entry.kind == "subtitle" && source.codec == "mov_text" && source.codecTag != Self.movTextTag {
                    // Subtitles an older version saved as "text" show as blank in Apple's players; rewriting the track
                    // (not just relabeling it, which would break a real QuickTime text track) fixes them.
                    options += ["-c:s:\(n)", "mov_text", "-tag:s:\(n)", Self.movTextTag]
                }
            }
            counts[entry.kind] = n + 1
            let spec = entry.kind == "audio" ? "a" : "s"
            let flags = [entry.isDefault ? "default" : nil, entry.isForced ? "forced" : nil].compactMap { $0 }
            options += ["-disposition:\(spec):\(n)", flags.isEmpty ? "0" : flags.joined(separator: "+")]
            let language = Self.subtitleTrackLanguage(entry.language, containerExtension: container)
            options += ["-metadata:s:\(spec):\(n)", "language=\(language ?? "und")"]
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            options += ["-metadata:s:\(spec):\(n)", "title=\(title)"]
            if isMOV {
                // Also replaces a handler name copied from the original, so a cleared title stays cleared.
                options += ["-metadata:s:\(spec):\(n)", "handler_name=\(title.isEmpty ? Self.movDefaultHandlerNames[entry.kind]! : title)"]
            }
        }

        // Written next to the destination under a temporary name, then moved into place once complete.
        let stem = output.deletingPathExtension().lastPathComponent
        let partial = directory.appendingPathComponent(".\(stem).partial-\(ProcessInfo.processInfo.processIdentifier).\(output.pathExtension)")
        let arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-nostats", "-y"]
            + inputs + maps + ["-c", "copy"] + options + [partial.path]
        do {
            // Copying keeps every byte of the kept tracks, so the copy is about the size of the original.
            let reader = Self.progressReader(totalSeconds: duration(video), totalBytes: size, onProgress)
            let status: Int32
            do {
                status = try run(ffmpeg, arguments, onLine: reader).status
            } catch is Failure {
                // `run` stops a tool that takes too long with a Failure.
                throw Failure("Timed out saving the video.")
            }
            guard status == 0 else {
                throw Failure("ffmpeg couldn't save these tracks in a .\(container) file (exit code \(status)). The video wasn't changed.")
            }
            guard ((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
                throw Failure("ffmpeg didn't write the video. It wasn't changed.")
            }
            if isMOV && !plan.contains(where: { $0.kind == "subtitle" && $0.isDefault }) {
                // With no default subtitle, ffmpeg turns the first one on anyway, and players would show it.
                try Self.disableMOVSubtitleTracks(partial)
            }
            // rename() swaps the file in whole, replacing the destination.
            guard rename(partial.path, output.path) == 0 else {
                throw Failure("Couldn't move the saved video into place: \(String(cString: strerror(errno))). It wasn't changed.")
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    // MARK: - .mp4/.mov boxes

    /// (type, payload start, box end) for each box between `start` and `end` of an .mp4/.mov byte range.
    private static func boxes(_ data: Data, _ start: Int, _ end: Int) -> [(type: Data, start: Int, end: Int)] {
        func number(_ offset: Int, _ count: Int) -> Int {
            data[(data.startIndex + offset)..<(data.startIndex + offset + count)].reduce(0) { $0 << 8 | Int($1) }
        }
        var found: [(Data, Int, Int)] = []
        var position = start
        while position + 8 <= end {
            var size = number(position, 4)
            var header = 8
            if size == 1 {
                guard position + 16 <= end else { break }
                size = number(position + 8, 8)
                header = 16
            } else if size == 0 {
                size = end - position
            }
            if size < header || position + size > end { break }
            let type = data[(data.startIndex + position + 4)..<(data.startIndex + position + 8)]
            found.append((Data(type), position + header, position + size))
            position += size
        }
        return found
    }

    /// Clears the "enabled" flag of every subtitle track in an .mp4/.mov file, in place, so players start with
    /// subtitles off. Only the track header flags change.
    static func disableMOVSubtitleTracks(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileEnd = Int(try handle.seekToEnd())
        func read(at offset: Int, _ count: Int) throws -> Data {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
        // Top-level boxes are walked by seeking, since the media data between them can be gigabytes.
        var position = 0
        var moov: (start: Int, end: Int)?
        while position + 8 <= fileEnd {
            let head = try read(at: position, 16)
            guard head.count >= 8 else { break }
            func number(_ range: Range<Int>) -> Int { head[range].reduce(0) { $0 << 8 | Int($1) } }
            var size = number(0..<4)
            var header = 8
            if size == 1 {
                guard head.count >= 16 else { break }
                size = number(8..<16)
                header = 16
            } else if size == 0 {
                size = fileEnd - position
            }
            if size < header { break }
            if head[4..<8] == Data("moov".utf8) {
                moov = (position + header, position + size)
                break
            }
            position += size
        }
        guard let moov else {
            throw Failure("Couldn't turn subtitles off by default: the saved video's track list wasn't found.")
        }

        let data = try read(at: moov.start, moov.end - moov.start)
        for trak in boxes(data, 0, data.count) where trak.type == Data("trak".utf8) {
            var flagsOffset: Int?
            var handlerType: Data?
            for child in boxes(data, trak.start, trak.end) {
                if child.type == Data("tkhd".utf8) {
                    // A full box: one version byte, then three flag bytes.
                    flagsOffset = child.start + 1
                } else if child.type == Data("mdia".utf8) {
                    for media in boxes(data, child.start, child.end) where media.type == Data("hdlr".utf8) && media.start + 12 <= data.count {
                        // Version and flags, pre_defined, then the handler type.
                        handlerType = data.subdata(in: (media.start + 8)..<(media.start + 12))
                    }
                }
            }
            guard let flagsOffset, flagsOffset + 3 <= data.count, let handlerType, movSubtitleHandlerTypes.contains(handlerType) else { continue }
            let flags = data[flagsOffset..<(flagsOffset + 3)].reduce(0) { $0 << 8 | Int($1) }
            if flags & 1 != 0 {
                let cleared = flags & ~1
                try handle.seek(toOffset: UInt64(moov.start + flagsOffset))
                try handle.write(contentsOf: Data([UInt8(cleared >> 16 & 0xFF), UInt8(cleared >> 8 & 0xFF), UInt8(cleared & 0xFF)]))
            }
        }
    }
}
