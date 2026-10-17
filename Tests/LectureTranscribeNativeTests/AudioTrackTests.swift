import Foundation
import XCTest

@testable import LectureTranscribeNative

final class AudioTrackTests: XCTestCase {
    private func track(_ index: Int, _ language: String, title: String = "", channels: Int? = 2, isDefault: Bool = false) -> AudioTrack {
        AudioTrack(index: index, language: language, title: title, codec: "aac", channels: channels, default: isDefault)
    }

    func testDecodesBackendTrackList() throws {
        let json = """
        [{"index": 0, "language": "ita", "title": "Italiano", "codec": "aac", "channels": 6, "default": true},
         {"index": 1, "language": "eng", "title": "", "codec": "ac3", "channels": null, "default": false}]
        """
        let tracks = try JSONDecoder().decode([AudioTrack].self, from: Data(json.utf8))
        XCTAssertEqual(tracks.map(\.languageCode), ["it", "en"])
        XCTAssertEqual(tracks[0].channels, 6)
        XCTAssertNil(tracks[1].channels)
    }

    func testLanguageCodeHandlesThreeLetterAndOlderTags() {
        XCTAssertEqual(track(0, "eng").languageCode, "en")
        XCTAssertEqual(track(0, "ita").languageCode, "it")
        XCTAssertEqual(track(0, "ger").languageCode, "de")
        XCTAssertEqual(track(0, "fre").languageCode, "fr")
        XCTAssertNil(track(0, "").languageCode)
    }

    func testPrefersTrackInSpokenLanguage() {
        let tracks = [track(0, "ita", isDefault: true), track(1, "eng")]
        XCTAssertEqual(AudioTrack.preferredIndex(in: tracks, spokenLanguage: "en"), 1)
    }

    func testFallsBackToDefaultTrackThenFirst() {
        let tracks = [track(0, "ita"), track(1, "fra", isDefault: true)]
        XCTAssertEqual(AudioTrack.preferredIndex(in: tracks, spokenLanguage: "en"), 1)
        XCTAssertEqual(AudioTrack.preferredIndex(in: tracks, spokenLanguage: ""), 1)
        XCTAssertEqual(AudioTrack.preferredIndex(in: [track(0, ""), track(1, "")], spokenLanguage: "en"), 0)
    }

    func testDisplayNameShowsNumberLanguageTitleAndLayout() {
        XCTAssertEqual(track(1, "eng", title: "Commentary", channels: 6).displayName, "Track 2: English · Commentary · 5.1")
        XCTAssertEqual(track(0, "ita", title: "Italian", channels: 2).displayName, "Track 1: Italian · Stereo")
        XCTAssertEqual(track(0, "", channels: nil).displayName, "Track 1: Unknown language")
    }
}
