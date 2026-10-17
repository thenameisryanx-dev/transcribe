import Foundation
import XCTest

@testable import LectureTranscribeNative

final class TrackEditorTests: XCTestCase {
    /// Shaped like the user's Episode 2: Italian audio first (default), English second, a forced Italian
    /// subtitle track (default), then English and SDH ones.
    private static let episodeTracks: [MediaTrack] = [
        MediaTrack(index: 0, kind: "video", codec: "hevc", language: "eng", title: "", default: true, forced: false, channels: nil, text: false),
        MediaTrack(index: 1, kind: "audio", codec: "eac3", language: "ita", title: "", default: true, forced: false, channels: 6, text: false),
        MediaTrack(index: 2, kind: "audio", codec: "eac3", language: "eng", title: "", default: false, forced: false, channels: 6, text: false),
        MediaTrack(index: 3, kind: "subtitle", codec: "subrip", language: "ita", title: "Forced", default: true, forced: true, channels: nil, text: true),
        MediaTrack(index: 4, kind: "subtitle", codec: "subrip", language: "eng", title: "", default: false, forced: false, channels: nil, text: true),
        MediaTrack(index: 5, kind: "subtitle", codec: "subrip", language: "hrv", title: "SDH", default: false, forced: false, channels: nil, text: true),
        MediaTrack(index: 6, kind: "attachment", codec: "ttf", language: "", title: "", default: false, forced: false, channels: nil, text: false),
    ]

    @MainActor
    private func loadedEditor() -> TrackEditorModel {
        let editor = TrackEditorModel()
        editor.open(videoPath: "/tmp/Episode 2.mkv")
        editor.load(Self.episodeTracks)
        return editor
    }

    @MainActor
    func testLoadSplitsTracksAndNormalizesLanguages() {
        let editor = loadedEditor()
        XCTAssertEqual(editor.audioTracks.map(\.language), ["it", "en"])
        // Croatian isn't one of the app's spoken languages, so its tag is kept as is.
        XCTAssertEqual(editor.subtitleTracks.map(\.language), ["it", "en", "hrv"])
        XCTAssertEqual(editor.subtitleTracks.map(\.isForced), [true, false, false])
        XCTAssertEqual(editor.videoSummary, "HEVC video · 1 attachment")
        XCTAssertEqual(editor.audioTracks[0].sourceDescription, "Track 2 · E-AC-3 · 5.1")
    }

    @MainActor
    func testOnlyOneDefaultPerKind() {
        let editor = loadedEditor()
        editor.setDefault(editor.audioTracks[1].id, kind: .audio, isOn: true)
        XCTAssertEqual(editor.audioTracks.map(\.isDefault), [false, true])
        // Subtitles are separate.
        XCTAssertEqual(editor.subtitleTracks.map(\.isDefault), [true, false, false])
        editor.setDefault(editor.audioTracks[1].id, kind: .audio, isOn: false)
        XCTAssertEqual(editor.audioTracks.map(\.isDefault), [false, false])
    }

    @MainActor
    func testLeavingOutATrackClearsItsDefaultAndMakingItDefaultKeepsIt() {
        let editor = loadedEditor()
        let forced = editor.subtitleTracks[0].id
        editor.setKeep(forced, kind: .subtitle, keep: false)
        XCTAssertFalse(editor.subtitleTracks[0].keep)
        XCTAssertFalse(editor.subtitleTracks[0].isDefault)
        editor.setDefault(forced, kind: .subtitle, isOn: true)
        XCTAssertTrue(editor.subtitleTracks[0].keep)
    }

    @MainActor
    func testMovingTracks() {
        let editor = loadedEditor()
        editor.move(editor.audioTracks[1].id, kind: .audio, by: -1)
        XCTAssertEqual(editor.audioTracks.map(\.language), ["en", "it"])
        // Moving past either end does nothing.
        editor.move(editor.audioTracks[0].id, kind: .audio, by: -1)
        XCTAssertEqual(editor.audioTracks.map(\.language), ["en", "it"])
        editor.move(.subtitle, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(editor.subtitleTracks.map(\.language), ["hrv", "it", "en"])
    }

    @MainActor
    func testAddedSubtitlesBecomeTheDefaultAtTheTop() {
        let editor = loadedEditor()
        editor.addSubtitleFile(path: "/tmp/Episode 2.srt", language: "en", makeDefault: true, atTop: true)
        XCTAssertEqual(editor.subtitleTracks.count, 4)
        XCTAssertTrue(editor.subtitleTracks[0].isAdded)
        XCTAssertEqual(editor.subtitleTracks.map(\.isDefault), [true, false, false, false])
        XCTAssertEqual(editor.subtitleTracks[0].sourceDescription, "Added · Episode 2.srt")
        editor.removeAddedTrack(editor.subtitleTracks[0].id)
        XCTAssertEqual(editor.subtitleTracks.count, 3)
        // The video's own tracks can't be removed from the list, only left out.
        editor.removeAddedTrack(editor.subtitleTracks[0].id)
        XCTAssertEqual(editor.subtitleTracks.count, 3)
    }

    @MainActor
    func testOnlySubtitleFilesCanBeAdded() {
        let editor = loadedEditor()
        editor.addSubtitleFile(path: "/tmp/movie.mp4")
        XCTAssertEqual(editor.subtitleTracks.count, 3)
        XCTAssertNotNil(editor.errorMessage)
    }

    @MainActor
    func testPlanListsKeptTracksInOrder() throws {
        let editor = loadedEditor()
        editor.move(editor.audioTracks[1].id, kind: .audio, by: -1)
        editor.setDefault(editor.audioTracks[0].id, kind: .audio, isOn: true)
        editor.addSubtitleFile(path: "/tmp/Episode 2.srt", language: "en", makeDefault: true, atTop: true)
        editor.setKeep(editor.subtitleTracks[2].id, kind: .subtitle, keep: false)
        editor.subtitleTracks[3].title = "Croatian SDH"

        let data = try XCTUnwrap(editor.planJSON().data(using: .utf8))
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(plan.map { $0["kind"] as? String }, ["audio", "audio", "subtitle", "subtitle", "subtitle"])
        XCTAssertEqual(plan.map { $0["index"] as? Int }, [2, 1, nil, 3, 5])
        XCTAssertEqual(plan[2]["file"] as? String, "/tmp/Episode 2.srt")
        XCTAssertEqual(plan.map { $0["default"] as? Bool }, [true, false, true, false, false])
        XCTAssertEqual(plan[3]["forced"] as? Bool, true)
        XCTAssertEqual(plan[4]["title"] as? String, "Croatian SDH")
        XCTAssertEqual(plan[4]["language"] as? String, "hrv")
    }

    @MainActor
    func testEditingClearsTheSavedMessage() {
        let editor = loadedEditor()
        XCTAssertNil(editor.lastSavedPath)
        editor.subtitleTracks[0].title = "Changed"
        XCTAssertNil(editor.lastSavedPath)
    }

    @MainActor
    func testOtherFormatsCantBeEdited() {
        let editor = TrackEditorModel()
        editor.open(videoPath: "/tmp/old.avi")
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(editor.canSave)
        XCTAssertNotNil(editor.errorMessage)
    }

    @MainActor
    func testSuggestedNameKeepsTheFormat() {
        let editor = TrackEditorModel()
        editor.open(videoPath: "/tmp/Show S01E02.mkv")
        XCTAssertEqual(editor.suggestedFileName, "Show S01E02.edited.mkv")
    }

    func testLanguageOptionsIncludeUnknownTags() {
        let options = TrackLanguage.options(including: "hrv")
        XCTAssertEqual(options.first?.code, "")
        XCTAssertTrue(options.contains { $0.code == "hrv" })
        XCTAssertTrue(options.contains { $0.code == "en" })
        XCTAssertEqual(TrackLanguage.options(including: "en").filter { $0.code == "en" }.count, 1)
        XCTAssertEqual(TrackLanguage.code(forTag: "fre"), "fr")
        XCTAssertEqual(TrackLanguage.code(forTag: ""), "")
    }

    func testTrackListDecodesBackendJSON() throws {
        let json = """
        [{"index": 3, "kind": "subtitle", "codec": "subrip", "language": "ita", "title": "Forced",
          "default": true, "forced": true, "channels": null, "text": true}]
        """
        let tracks = try JSONDecoder().decode([MediaTrack].self, from: Data(json.utf8))
        XCTAssertEqual(tracks.first?.index, 3)
        XCTAssertEqual(tracks.first?.forced, true)
        XCTAssertNil(tracks.first?.channels)
    }

    @MainActor
    func testSaveIsOnlyOfferedWithChanges() {
        let editor = loadedEditor()
        XCTAssertFalse(editor.hasChanges)
        XCTAssertFalse(editor.canSave)
        editor.move(editor.audioTracks[1].id, kind: .audio, by: -1)
        XCTAssertTrue(editor.hasChanges)
        // Moving it back means there's nothing to save again.
        editor.move(editor.audioTracks[0].id, kind: .audio, by: 1)
        XCTAssertFalse(editor.hasChanges)
        editor.subtitleTracks[2].title = "Croatian"
        XCTAssertTrue(editor.hasChanges)
    }

    @MainActor
    func testSaveAsIsOfferedWithoutChanges() {
        let editor = loadedEditor()
        XCTAssertFalse(editor.canSave)
        XCTAssertTrue(editor.canSaveAs)
    }

    @MainActor
    func testAddedSubtitlesCountAsAChange() {
        let editor = loadedEditor()
        editor.addSubtitleFile(path: "/tmp/Episode 2.srt", language: "en", makeDefault: true, atTop: true)
        XCTAssertTrue(editor.hasChanges)
    }

    @MainActor
    func testOpeningAnotherVideoAsksAboutUnsavedChanges() {
        let editor = loadedEditor()
        editor.open(videoPath: "/tmp/Episode 2.mkv")
        editor.load(Self.episodeTracks)
        editor.setKeep(editor.subtitleTracks[1].id, kind: .subtitle, keep: false)

        editor.requestOpen(videoPath: "/tmp/Episode 3.mkv")
        XCTAssertEqual(editor.pendingOpen?.videoPath, "/tmp/Episode 3.mkv")
        XCTAssertEqual(editor.videoPath, "/tmp/Episode 2.mkv")

        // Cancel keeps the video and its changes.
        editor.resolvePendingOpen(save: nil)
        XCTAssertNil(editor.pendingOpen)
        XCTAssertEqual(editor.videoPath, "/tmp/Episode 2.mkv")
        XCTAssertTrue(editor.hasChanges)

        // Don't Save opens the other video.
        editor.requestOpen(videoPath: "/tmp/Episode 3.mkv")
        editor.resolvePendingOpen(save: false)
        XCTAssertNil(editor.pendingOpen)
        XCTAssertEqual(editor.videoPath, "/tmp/Episode 3.mkv")
    }

    @MainActor
    func testOpeningWithoutChangesDoesntAsk() {
        let editor = loadedEditor()
        editor.open(videoPath: "/tmp/Episode 2.mkv")
        editor.load(Self.episodeTracks)
        editor.requestOpen(videoPath: "/tmp/Episode 3.mkv")
        XCTAssertNil(editor.pendingOpen)
        XCTAssertEqual(editor.videoPath, "/tmp/Episode 3.mkv")
    }
}
