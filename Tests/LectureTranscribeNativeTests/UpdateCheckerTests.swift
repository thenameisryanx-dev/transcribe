import XCTest
@testable import LectureTranscribeNative

final class UpdateCheckerTests: XCTestCase {
    func testVersionParsingAcceptsTagPrefixAndRejectsJunk() {
        XCTAssertEqual(AppVersion("v1.2.0")?.components, [1, 2, 0])
        XCTAssertEqual(AppVersion(" 1.10 ")?.components, [1, 10])
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1.2-beta"))
        XCTAssertNil(AppVersion("1..2"))
    }

    func testVersionComparisonIsNumericAndIgnoresTrailingZeros() {
        XCTAssertLessThan(AppVersion("1.9")!, AppVersion("1.10")!)
        XCTAssertLessThan(AppVersion("1.0")!, AppVersion("1.0.1")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1.0.0")!)
        XCTAssertFalse(AppVersion("2.0")! < AppVersion("1.9.9")!)
    }

    func testNewerReleasePrefersDMGForHostArch() throws {
        let json = """
        {
          "tag_name": "v1.1.0",
          "html_url": "https://github.com/example/releases/tag/v1.1.0",
          "assets": [
            {"name": "Lecture-Transcribe-1.1.0-x86_64.dmg", "browser_download_url": "https://example.com/x86.dmg"},
            {"name": "Lecture-Transcribe-1.1.0-arm64.dmg", "browser_download_url": "https://example.com/arm.dmg"}
          ]
        }
        """
        let update = try XCTUnwrap(UpdateChecker.update(
            fromLatestReleaseJSON: Data(json.utf8),
            currentVersion: AppVersion("1.0.0")!,
            arch: "arm64"
        ))
        XCTAssertEqual(update.version, "1.1.0")
        XCTAssertEqual(update.downloadURL.absoluteString, "https://example.com/arm.dmg")
    }

    func testReleaseWithoutMatchingDMGFallsBackToReleasePage() throws {
        let json = #"{"tag_name": "1.1", "html_url": "https://github.com/example/releases/tag/1.1", "assets": []}"#
        let update = try XCTUnwrap(UpdateChecker.update(
            fromLatestReleaseJSON: Data(json.utf8),
            currentVersion: AppVersion("1.0")!,
            arch: "arm64"
        ))
        XCTAssertEqual(update.downloadURL.absoluteString, "https://github.com/example/releases/tag/1.1")
    }

    func testSameOrOlderReleaseIsNotAnUpdate() {
        let json = #"{"tag_name": "v1.0.0", "html_url": "https://github.com/example", "assets": []}"#
        XCTAssertNil(UpdateChecker.update(fromLatestReleaseJSON: Data(json.utf8), currentVersion: AppVersion("1.0")!, arch: "arm64"))
        XCTAssertNil(UpdateChecker.update(fromLatestReleaseJSON: Data(json.utf8), currentVersion: AppVersion("1.2")!, arch: "arm64"))
        XCTAssertNil(UpdateChecker.update(fromLatestReleaseJSON: Data("not json".utf8), currentVersion: AppVersion("1.0")!, arch: "arm64"))
    }
}
