import XCTest
@testable import ImageGlassCore

/// Tests for the release/version MCP tools (app_version, list_releases,
/// check_for_update). See docs/releases.mdx.
final class MCPReleasesToolsTests: XCTestCase {

    private var tmpHome: URL!
    private var savedHome: String?

    override func setUpWithError() throws {
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-rel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        savedHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpHome.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        if let h = savedHome { setenv("HOME", h, 1) }
    }

    // MARK: - Descriptors

    func testDescriptors_includeReleasesTools() {
        let tools = MCPTools()
        let names = Set(tools.descriptors().map(\.name))
        XCTAssertTrue(names.contains("app_version"))
        XCTAssertTrue(names.contains("list_releases"))
        XCTAssertTrue(names.contains("check_for_update"))
    }

    // MARK: - app_version

    func testAppVersion_returnsMarketingVersionAndChannel() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "app_version", arguments: [:])
        XCTAssertFalse(r.isError ?? false)
        let text = r.content.first?.text ?? ""
        XCTAssertTrue(text.contains(AppVersion.marketingVersion))
        XCTAssertTrue(text.contains(AppVersion.channel.rawValue))
        XCTAssertTrue(text.contains("9.5.0.515"))  // current_stable_upstream
    }

    // MARK: - list_releases

    func testListReleases_default_includesBothOrigins() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "list_releases", arguments: [:])
        XCTAssertFalse(r.isError ?? false)
        let text = r.content.first?.text ?? ""
        XCTAssertTrue(text.contains("\"origin\""))
        XCTAssertTrue(text.contains("mac_fork"))
        XCTAssertTrue(text.contains("upstream"))
    }

    func testListReleases_filterMacFork_excludesUpstream() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "list_releases", arguments: ["origin": "mac_fork"])
        XCTAssertFalse(r.isError ?? false)
        let text = r.content.first?.text ?? ""
        XCTAssertTrue(text.contains("mac_fork"))
        XCTAssertFalse(text.contains("\"upstream\""))
    }

    func testListReleases_filterUpstream_excludesMacFork() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "list_releases", arguments: ["origin": "upstream"])
        XCTAssertFalse(r.isError ?? false)
        let text = r.content.first?.text ?? ""
        XCTAssertTrue(text.contains("upstream"))
        XCTAssertFalse(text.contains("\"mac_fork\""))
    }

    // MARK: - check_for_update

    func testCheckForUpdate_isDisabledByDefault() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "check_for_update", arguments: [:])
        XCTAssertTrue(r.isError ?? false,
                      "check_for_update without force=true should report disabledByPolicy as isError")
        let text = r.content.first?.text ?? ""
        XCTAssertTrue(text.localizedCaseInsensitiveContains("disabled"))
    }
}
