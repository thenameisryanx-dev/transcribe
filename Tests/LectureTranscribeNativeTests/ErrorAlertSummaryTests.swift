import XCTest

@testable import LectureTranscribeNative

final class ErrorAlertSummaryTests: XCTestCase {
    func testShortMessageIsUnchanged() {
        let message = "OpenAI rejected your API key. Set a valid key in Settings, then try again."
        XCTAssertEqual(TranscribeViewModel.alertSummary(for: message), message)
    }

    func testTracebackIsDroppedFromAlert() {
        let message = "Error code: 401\n\nTraceback (most recent call last):\n  File \"x.py\", line 1, in f\n    foo()"
        XCTAssertEqual(
            TranscribeViewModel.alertSummary(for: message),
            "Error code: 401\n\nFull details are in the Run Log."
        )
    }

    func testLongMessageIsTruncated() {
        let message = String(repeating: "a", count: 1_000)
        let summary = TranscribeViewModel.alertSummary(for: message, maxLength: 50)
        XCTAssertTrue(summary.hasPrefix(String(repeating: "a", count: 50) + "…"))
        XCTAssertTrue(summary.hasSuffix("Full details are in the Run Log."))
    }
}
