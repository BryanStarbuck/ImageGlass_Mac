import XCTest
@testable import ImageGlassCore

final class MCPToolsTests: XCTestCase {

    private var tmpStorageDir: URL!
    private var originalAppSupport: String?

    /// We rebind the home dir for the test process so LocalStorage writes into a
    /// temp tree instead of the user's real `~/Library/Application Support`.
    override func setUpWithError() throws {
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        originalAppSupport = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpHome.path, 1)
        tmpStorageDir = tmpHome
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpStorageDir)
        if let original = originalAppSupport {
            setenv("HOME", original, 1)
        }
    }

    func testCreateAndListScope() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "test-scope",
            "directories": [tmpStorageDir.path] as [Any?],
            "extensions": ["png"] as [Any?],
        ])

        let listResult = try tools.call(name: "list_scopes", arguments: [:])
        XCTAssertFalse(listResult.isError ?? false)
        XCTAssertTrue(listResult.content.first?.text.contains("test-scope") ?? false)
    }

    func testCreateRejectsDuplicate() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "dup"])
        let second = try tools.call(name: "create_scope", arguments: ["name": "dup"])
        XCTAssertTrue(second.isError ?? false)
    }

    func testEvaluateScopeWritesResolvedFiles() throws {
        let testDir = tmpStorageDir.appendingPathComponent("imgs", isDirectory: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: testDir.appendingPathComponent("a.png"))
        try Data("x".utf8).write(to: testDir.appendingPathComponent("b.png"))

        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "imgs",
            "directories": [testDir.path] as [Any?],
            "extensions": ["png"] as [Any?],
        ])

        let result = try tools.call(name: "evaluate_scope", arguments: ["name": "imgs"])
        XCTAssertFalse(result.isError ?? false)
        XCTAssertTrue(result.content.first?.text.contains("a.png") ?? false)
        XCTAssertTrue(result.content.first?.text.contains("b.png") ?? false)

        let reloaded = try LocalStorage.shared.loadScope("imgs")
        XCTAssertEqual(reloaded.resolvedFiles.count, 2)
        XCTAssertNotNil(reloaded.lastEvaluated)
    }
}
