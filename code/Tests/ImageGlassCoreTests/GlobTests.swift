import XCTest
@testable import ImageGlassCore

final class GlobTests: XCTestCase {
    func testLiteralMatch() {
        XCTAssertTrue(Glob.match("foo.png", "foo.png"))
        XCTAssertFalse(Glob.match("foo.png", "bar.png"))
    }

    func testStar() {
        XCTAssertTrue(Glob.match("*.png", "anything.png"))
        XCTAssertTrue(Glob.match("*", ""))
        XCTAssertTrue(Glob.match("*.png", ".png"))
        XCTAssertFalse(Glob.match("*.png", "foo.jpg"))
    }

    func testQuestionMark() {
        XCTAssertTrue(Glob.match("a?c", "abc"))
        XCTAssertFalse(Glob.match("a?c", "ac"))
        XCTAssertFalse(Glob.match("a?c", "abbc"))
    }

    func testCharacterClass() {
        XCTAssertTrue(Glob.match("[abc].png", "a.png"))
        XCTAssertTrue(Glob.match("[a-z].png", "m.png"))
        XCTAssertFalse(Glob.match("[a-z].png", "1.png"))
        XCTAssertTrue(Glob.match("[!0-9].png", "a.png"))
        XCTAssertFalse(Glob.match("[!0-9].png", "5.png"))
    }

    func testPatternsForExcludes() {
        XCTAssertTrue(Glob.match("*_old*", "screenshot_old_2.png"))
        XCTAssertTrue(Glob.match("*.tmp", "draft.tmp"))
        XCTAssertFalse(Glob.match("*_old*", "screenshot.png"))
    }
}
