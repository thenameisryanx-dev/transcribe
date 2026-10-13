import XCTest
@testable import LectureTranscribeNative

final class RecentContextPromptsTests: XCTestCase {
    func testAddingPutsNewestFirstAndDropsExactDuplicate() {
        let recent = RecentContextPrompts.adding("Biology, week 2", to: ["Chemistry", "Biology, week 2", "Physics"])
        XCTAssertEqual(recent, ["Biology, week 2", "Chemistry", "Physics"])
    }

    func testAddingTrimsAndIgnoresBlank() {
        XCTAssertEqual(RecentContextPrompts.adding("  Physics \n", to: []), ["Physics"])
        XCTAssertEqual(RecentContextPrompts.adding("   ", to: ["Physics"]), ["Physics"])
    }

    func testAddingKeepsAtMostLimit() {
        let existing = (1...RecentContextPrompts.limit).map { "Lecture \($0)" }
        let recent = RecentContextPrompts.adding("New", to: existing)
        XCTAssertEqual(recent.count, RecentContextPrompts.limit)
        XCTAssertEqual(recent.first, "New")
        XCTAssertFalse(recent.contains("Lecture \(RecentContextPrompts.limit)"))
    }

    func testMenuTitleIsOneShortLine() {
        XCTAssertEqual(RecentContextPrompts.menuTitle(for: "Cell Biology\nProf. Okonkwo"), "Cell Biology Prof. Okonkwo")
        let title = RecentContextPrompts.menuTitle(for: String(repeating: "a", count: 100), maxLength: 20)
        XCTAssertEqual(title.count, 20)
        XCTAssertTrue(title.hasSuffix("…"))
    }
}
