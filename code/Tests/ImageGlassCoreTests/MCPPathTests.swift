import XCTest
@testable import ImageGlassCore

/// Spec §10: "Path arguments are normalized and expanded (`~` → home
/// directory) before use." `MCPPath` is the single point where every
/// tool that accepts a directory list normalizes its input.
final class MCPPathTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpHome.path, 1)
    }

    override func tearDownWithError() throws {
        if let h = originalHome { setenv("HOME", h, 1) }
        try? FileManager.default.removeItem(at: tmpHome)
    }

    func testTildeExpands() {
        // A tilde path under HOME should round-trip back to a tilde path on
        // the persistence side (matches how ScopeEvaluator writes resolved
        // file paths).
        let n = MCPPath.normalizeDirectory("~/Pictures")
        XCTAssertEqual(n, "~/Pictures")
    }

    func testAbsolutePathPassesThrough() {
        let n = MCPPath.normalizeDirectory("/tmp/foo")
        XCTAssertEqual(n, "/tmp/foo")
    }

    func testRelativePathIsRootedAtHome() {
        // The MCP server has no meaningful CWD; relative paths are anchored
        // at $HOME so the persisted form is stable.
        let n = MCPPath.normalizeDirectory("Pictures")
        XCTAssertEqual(n, "~/Pictures")
    }

    func testCollapsesDotDot() {
        let n = MCPPath.normalizeDirectory("/tmp/a/../b")
        XCTAssertEqual(n, "/tmp/b")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(MCPPath.normalizeDirectory("  /tmp/x  "), "/tmp/x")
    }

    func testNormalizeArrayDeduplicates() {
        let result = MCPPath.normalizeDirectories([
            "/tmp/a",
            "/tmp/a",
            "/tmp/a/../a", // collapses to /tmp/a
            "/tmp/b",
        ])
        XCTAssertEqual(result, ["/tmp/a", "/tmp/b"])
    }

    func testNormalizeArraySkipsEmpty() {
        let result = MCPPath.normalizeDirectories(["", "   ", "/tmp/x"])
        XCTAssertEqual(result, ["/tmp/x"])
    }
}
