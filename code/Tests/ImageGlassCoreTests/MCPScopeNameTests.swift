import XCTest
@testable import ImageGlassCore

/// Spec §4.4: scope name must be a "short, file-system-safe identifier."
/// `MCPScopeName` is the single point that enforces that contract; every
/// scope-name-bearing tool funnels its argument through `validate`.
final class MCPScopeNameTests: XCTestCase {

    func testAcceptsSimpleAlphanumeric() throws {
        XCTAssertEqual(try MCPScopeName.validate("photos"), "photos")
        XCTAssertEqual(try MCPScopeName.validate("p123"), "p123")
        XCTAssertEqual(try MCPScopeName.validate("Photos2026"), "Photos2026")
    }

    func testAcceptsDotsDashesUnderscores() throws {
        XCTAssertEqual(try MCPScopeName.validate("a.b-c_d"), "a.b-c_d")
        XCTAssertEqual(try MCPScopeName.validate("a-1"), "a-1")
    }

    func testTrimsWhitespace() throws {
        XCTAssertEqual(try MCPScopeName.validate("  hi  "), "hi")
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try MCPScopeName.validate(""))
        XCTAssertThrowsError(try MCPScopeName.validate("   "))
    }

    func testRejectsSlashes() {
        // Path traversal guard.
        XCTAssertThrowsError(try MCPScopeName.validate("../etc"))
        XCTAssertThrowsError(try MCPScopeName.validate("a/b"))
        XCTAssertThrowsError(try MCPScopeName.validate("a\\b"))
    }

    func testRejectsSpaces() {
        XCTAssertThrowsError(try MCPScopeName.validate("hello world"))
    }

    func testRejectsLeadingDot() {
        XCTAssertThrowsError(try MCPScopeName.validate(".hidden"))
        XCTAssertThrowsError(try MCPScopeName.validate("."))
        XCTAssertThrowsError(try MCPScopeName.validate(".."))
    }

    func testRejectsOverlyLong() {
        let long = String(repeating: "a", count: MCPScopeName.maxLength + 1)
        XCTAssertThrowsError(try MCPScopeName.validate(long))
    }

    func testRejectsControlChars() {
        XCTAssertThrowsError(try MCPScopeName.validate("a\nb"))
        XCTAssertThrowsError(try MCPScopeName.validate("a\tb"))
    }
}
