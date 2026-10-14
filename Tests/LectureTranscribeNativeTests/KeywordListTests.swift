import XCTest
@testable import LectureTranscribeNative

final class KeywordListTests: XCTestCase {
    func testParseSplitsOnCommasAndNewLines() {
        XCTAssertEqual(
            KeywordList.parse("Sheldon, Leslie   Winkle\nWolowitz,,\n  Raj  "),
            ["Sheldon", "Leslie Winkle", "Wolowitz", "Raj"]
        )
    }

    func testParseDropsBlanksAndCaseInsensitiveRepeats() {
        XCTAssertEqual(KeywordList.parse("ATP, atp , ,ATP synthase"), ["ATP", "ATP synthase"])
        XCTAssertEqual(KeywordList.parse("  \n , "), [])
    }

    func testRejectsAngleBrackets() {
        XCTAssertTrue(KeywordList.isRejected("<b>bold"))
        XCTAssertTrue(KeywordList.isRejected("a > b"))
        XCTAssertFalse(KeywordList.isRejected("C++"))
    }

    func testDisplayTextParsesBackToSameKeywords() {
        let keywords = ["Okonkwo", "mitochondria", "ATP synthase"]
        XCTAssertEqual(KeywordList.parse(KeywordList.displayText(keywords)), keywords)
    }
}
