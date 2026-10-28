import Foundation
import XCTest

@testable import LectureTranscribeNative

/// The Tracks pane's listing and saving, in each format it supports: video, English + Spanish audio, one subtitle.
/// Ported from the backend's TrackEditingTests, plus what `BackendClient` adds (Save, errors, cancel).
final class TrackFilesTests: XCTestCase {
    private static let formats = ["mp4", "mov", "mkv"]
    private var directory: URL!
    private var tools: MediaTools!
    private var srt: URL!
    private var videos: [String: URL] = [:]

    private func ffmpeg(_ arguments: [String]) throws {
        let result = try tools.run(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + arguments)
        XCTAssertEqual(result.status, 0, result.errors)
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tools = try MediaTools.located()
        srt = directory.appendingPathComponent("french.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nBonjour\n".utf8).write(to: srt)
        let source = directory.appendingPathComponent("source.mp4")
        try ffmpeg([
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=1",
            "-f", "lavfi", "-i", "sine=duration=1",
            "-f", "lavfi", "-i", "sine=frequency=660:duration=1",
            "-i", srt.path,
            "-map", "0", "-map", "1", "-map", "2", "-map", "3",
            "-c:v", "libx264", "-c:a", "aac", "-c:s", "mov_text",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=spa",
            "-metadata:s:s:0", "language=eng",
            source.path,
        ])
        try ffmpeg(["-i", source.path, "-map", "0", "-c", "copy", directory.appendingPathComponent("source.mov").path])
        try ffmpeg(["-i", source.path, "-map", "0", "-c", "copy", "-c:s", "srt", directory.appendingPathComponent("source.mkv").path])
        videos = Dictionary(uniqueKeysWithValues: Self.formats.map { ($0, directory.appendingPathComponent("source.\($0)")) })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func track(_ kind: String, _ index: Int, _ language: String, _ title: String = "", default isDefault: Bool = false) -> TrackPlanEntry {
        TrackPlanEntry(kind: kind, source: .original(index: index), language: language, title: title, isDefault: isDefault, isForced: false)
    }

    private func added(_ file: URL, _ language: String, _ title: String = "", default isDefault: Bool = false) -> TrackPlanEntry {
        TrackPlanEntry(kind: "subtitle", source: .file(path: file.path), language: language, title: title, isDefault: isDefault, isForced: false)
    }

    private func save(_ video: URL, _ name: String, _ plan: [TrackPlanEntry]) throws -> [MediaTrack] {
        let output = directory.appendingPathComponent("\(name).\(video.pathExtension)")
        try tools.saveEditedTracks(video: video, output: output, plan: plan)
        return try tools.mediaTracks(output).filter { $0.kind == "audio" || $0.kind == "subtitle" }
    }

    func testTracksAreListedInFileOrder() throws {
        let tracks = try tools.mediaTracks(videos["mp4"]!)
        XCTAssertEqual(tracks.map(\.kind), ["video", "audio", "audio", "subtitle"])
        XCTAssertEqual(tracks.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(tracks.map(\.language), ["", "eng", "spa", "eng"], "\"und\" is listed as no language")
        XCTAssertEqual(tracks[1].channels, 1)
        XCTAssertTrue(tracks[3].text)
        XCTAssertThrowsError(try tools.mediaTracks(srt.deletingLastPathComponent().appendingPathComponent("missing.mp4"))) {
            XCTAssertEqual($0.localizedDescription, "Couldn't read the tracks in missing.mp4. Is it a video file?")
        }
    }

    func testTitlesOrderAndAddedSubtitlesAreSaved() throws {
        for format in Self.formats {
            let saved = try save(videos[format]!, "edited", [
                track("audio", 2, "spa", "Spanish", default: true),
                track("subtitle", 3, "eng", "English subs", default: true),
                added(srt, "fra", "French"),
            ])
            XCTAssertEqual(saved.map(\.kind), ["audio", "subtitle", "subtitle"], format)
            XCTAssertEqual(saved.map(\.title), ["Spanish", "English subs", "French"], format)
            XCTAssertEqual(saved[0].language, "spa", format)
            XCTAssertEqual(saved.map(\.default), [true, true, false], format)
        }
    }

    func testNoDefaultSubtitleStaysOff() throws {
        // ffmpeg turns the first .mp4/.mov subtitle on when none is the default; the save turns it off again.
        for format in Self.formats {
            let saved = try save(videos[format]!, "subs-off", [
                track("audio", 1, "eng", default: true),
                added(srt, "fra"),
                track("subtitle", 3, "eng"),
            ])
            XCTAssertEqual(saved.map(\.default), [true, false, false], format)
        }
    }

    func testClearedTitleStaysCleared() throws {
        for format in Self.formats {
            let named = directory.appendingPathComponent("named.\(format)")
            try tools.saveEditedTracks(video: videos[format]!, output: named, plan: [track("audio", 1, "eng", "Lecture", default: true)])
            let saved = try save(named, "renamed", [track("audio", 1, "eng", "", default: true)])
            XCTAssertEqual(saved[0].title, "", format)
        }
    }

    private func subtitleTags(_ video: URL) throws -> [String] {
        try tools.mediaTracks(video).filter { $0.kind == "subtitle" }.map(\.codecTag)
    }

    func testSubtitlesInMP4AndMOVAreTaggedForApplePlayers() throws {
        // Apple's players list a mov_text track tagged "text" (ffmpeg's default in a .mov) but show nothing.
        for format in ["mp4", "mov"] {
            let output = directory.appendingPathComponent("tagged.\(format)")
            try tools.saveEditedTracks(video: videos[format]!, output: output, plan: [
                track("audio", 1, "eng", default: true),
                track("subtitle", 3, "eng"),
                added(srt, "fra", default: true),
            ])
            XCTAssertEqual(try subtitleTags(output), ["tx3g", "tx3g"], format)
        }
    }

    func testBlankSubtitlesSavedByOlderVersionsAreFixed() throws {
        let old = directory.appendingPathComponent("old.mov")
        try ffmpeg(["-i", videos["mov"]!.path, "-i", srt.path, "-map", "0:v", "-map", "0:a", "-map", "1:0",
                    "-c", "copy", "-c:s", "mov_text", old.path])
        XCTAssertEqual(try subtitleTags(old), ["text"])
        let subtitle = try XCTUnwrap(try tools.mediaTracks(old).first { $0.kind == "subtitle" }).index
        let fixed = directory.appendingPathComponent("fixed.mov")
        try tools.saveEditedTracks(video: old, output: fixed, plan: [track("audio", 1, "eng", default: true), track("subtitle", subtitle, "fra", default: true)])
        XCTAssertEqual(try subtitleTags(fixed), ["tx3g"])
        let back = directory.appendingPathComponent("back.srt")
        try ffmpeg(["-i", fixed.path, "-map", "0:s:0", back.path])
        XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains("Bonjour"))
    }

    func testGenericHandlerNamesAreNotTitles() throws {
        let video = directory.appendingPathComponent("phone.mov")
        try ffmpeg(["-i", videos["mp4"]!.path, "-map", "0", "-c", "copy",
                    "-metadata:s:a:0", "handler_name=Core Media Audio",
                    "-metadata:s:a:1", "handler_name=Commentary",
                    video.path])
        XCTAssertEqual(try tools.mediaTracks(video).filter { $0.kind == "audio" }.map(\.title), ["", "Commentary"])
    }

    func testPlansThatCantBeSavedAreRefused() throws {
        let mp4 = videos["mp4"]!
        func refusal(_ output: URL, _ plan: [TrackPlanEntry], replaceOriginal: Bool = false) -> String? {
            do {
                try tools.saveEditedTracks(video: mp4, output: output, plan: plan, replaceOriginal: replaceOriginal)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let other = directory.appendingPathComponent("other.mp4")
        XCTAssertEqual(refusal(mp4, []), "Saving under the video's own name replaces it. Use Save to do that, or choose another name.")
        XCTAssertEqual(refusal(other, [], replaceOriginal: true), "Save replaces the video itself, so it can't be given another name.")
        XCTAssertEqual(refusal(directory.appendingPathComponent("other.mkv"), []), "Save the video as a .mp4 file, the same format as the original.")
        XCTAssertEqual(refusal(other, [track("subtitle", 1, "eng")]), "The video has no subtitle track #1.")
        XCTAssertEqual(refusal(other, [added(directory.appendingPathComponent("notes.txt"), "eng")]),
                       "notes.txt isn't a subtitle file the app can add (.srt, .ass, .ssa or .vtt).")
        XCTAssertEqual(refusal(other, [TrackPlanEntry(kind: "video", source: .original(index: 0), language: "", title: "", isDefault: false, isForced: false)]),
                       "Unknown track kind: 'video'.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        XCTAssertThrowsError(try tools.saveEditedTracks(video: srt, output: directory.appendingPathComponent("x.srt"), plan: [])) {
            XCTAssertEqual($0.localizedDescription, "Tracks can only be edited in .m4v, .mkv, .mov, .mp4 videos.")
        }
    }

    /// Plans as the Tracks pane writes them.
    private func planJSON(_ entries: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]), as: UTF8.self)
    }

    func testSaveReplacesTheVideoAndReportsProgress() async throws {
        let video = videos["mkv"]!
        let events = EventLog()
        let json = try planJSON([["kind": "audio", "index": 2, "language": "es", "title": "Spanish", "default": true, "forced": false]])
        try await BackendClient().saveTracks(inputPath: video.path, outputPath: video.path, planJSON: json, replaceOriginal: true) {
            events.append($0)
        }
        let audio = try tools.mediaTracks(video).filter { $0.kind == "audio" }
        XCTAssertEqual(audio.map(\.title), ["Spanish"])
        XCTAssertEqual(audio.map(\.language), ["spa"])
        let progress = events.all.compactMap { if case let .progress(value) = $0 { return value } else { return nil } }
        XCTAssertFalse(progress.isEmpty)
        XCTAssertEqual(progress, progress.sorted(), "Progress only moves forward")
        guard case let .done(path)? = events.all.last else { return XCTFail("No done event: \(events.all)") }
        XCTAssertEqual(path, video.resolvingSymlinksInPath().path)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".partial-") }
        XCTAssertEqual(leftovers, [])
    }

    func testAFailedSaveReportsAnError() async throws {
        let events = EventLog()
        let json = try planJSON([["kind": "audio", "index": 9, "language": "", "title": "", "default": true, "forced": false]])
        do {
            try await BackendClient().saveTracks(inputPath: videos["mp4"]!.path, outputPath: directory.appendingPathComponent("out.mp4").path, planJSON: json) {
                events.append($0)
            }
            XCTFail("The save should fail")
        } catch {}
        guard case let .error(message)? = events.all.last else { return XCTFail("No error event: \(events.all)") }
        XCTAssertEqual(message, "The video has no audio track #9.")
    }

    func testACancelledSaveLeavesTheVideoAsItWas() async throws {
        let video = videos["mkv"]!
        let before = try Data(contentsOf: video)
        let client = BackendClient()
        let json = try planJSON([["kind": "audio", "index": 1, "language": "en", "title": "Renamed", "default": true, "forced": false]])
        do {
            // Cancelled while ffmpeg is writing the new file: its first progress report.
            try await client.saveTracks(inputPath: video.path, outputPath: video.path, planJSON: json, replaceOriginal: true) { event in
                if case .progress = event { client.cancelActiveRun() }
            }
            XCTFail("The save should have been cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: video), before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".partial-") }
        XCTAssertEqual(leftovers, [])
    }

    /// Waits for the editor to finish loading or saving.
    @MainActor
    private func settle(_ editor: TrackEditorModel) async throws {
        for _ in 0..<200 where editor.isLoading || editor.isSaving {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(editor.isLoading || editor.isSaving, "Still busy")
    }

    /// The Tracks pane's model, end to end: open a video, rename and drop tracks, Save, and see the saved file.
    @MainActor
    func testTheTracksPaneSavesItsEdits() async throws {
        let video = videos["mov"]!
        let editor = TrackEditorModel()
        editor.open(videoPath: video.path)
        try await settle(editor)
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(editor.audioTracks.count, 2)
        XCTAssertEqual(editor.subtitleTracks.count, 1)

        editor.audioTracks[1].title = "Español"
        editor.audioTracks.swapAt(0, 1)
        editor.subtitleTracks[0].keep = false
        XCTAssertTrue(editor.canSave)
        editor.save()
        try await settle(editor)
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(editor.lastSavedPath, video.resolvingSymlinksInPath().path)

        let saved = try tools.mediaTracks(video).filter { $0.kind != "video" }
        XCTAssertEqual(saved.map(\.kind), ["audio", "audio"])
        XCTAssertEqual(saved.map(\.title), ["Español", ""])
        XCTAssertEqual(saved.map(\.language), ["spa", "eng"])
        // The editor reopens the saved file, which now has no changes to save.
        XCTAssertEqual(editor.audioTracks.map(\.title), ["Español", ""])
        XCTAssertFalse(editor.canSave)
    }

    func testAudioTracksAreListedForTheTranscribePane() async throws {
        let tracks = try await BackendClient().fetchAudioTracks(inputPath: videos["mov"]!.path)
        XCTAssertEqual(tracks.map(\.index), [0, 1])
        XCTAssertEqual(tracks.map(\.languageCode), ["en", "es"])
        do {
            _ = try await BackendClient().fetchAudioTracks(inputPath: directory.appendingPathComponent("missing.mp4").path)
            XCTFail("A missing file should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Input file not found:"), error.localizedDescription)
        }
    }
}
