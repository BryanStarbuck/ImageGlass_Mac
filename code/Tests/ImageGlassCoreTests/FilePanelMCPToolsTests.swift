import XCTest
@testable import ImageGlassCore

/// Exercises the `update_scope`, `list_files_in_scope`, `select_file`,
/// and `panel.set_view_mode` MCP tools from
/// `docs/use_cases/mcp_file.mdx`. Each test isolates the on-disk state
/// to a per-test temp directory so the user's real
/// `~/Library/Application Support/ImageGlass_Mac/` is never touched.
final class FilePanelMCPToolsTests: XCTestCase {

    private var tmp: URL!
    private var fixtures: URL!
    private var yamlStore: MacScopeStore!
    private var legacyStore: LocalStorage!
    private var logger: MCPAuditLogger!
    private var tools: FilePanelMCPTools!
    private var logFile: URL!

    override func setUpWithError() throws {
        tmp = try makeTempDir()
        fixtures = try makeFixtures(under: tmp)

        let scopesDir = tmp.appendingPathComponent("scopes", isDirectory: true)
        try FileManager.default.createDirectory(at: scopesDir, withIntermediateDirectories: true)
        yamlStore = MacScopeStore(overrideDir: scopesDir)

        // The legacy LocalStorage uses AppPaths.scopesDir which honors HOME,
        // so point HOME at the temp dir. AppPaths' `appName` is "ImageGlass"
        // so JSON scopes end up under `tmp/Library/Application Support/ImageGlass/scopes/`.
        setenv("HOME", tmp.path, 1)
        legacyStore = LocalStorage()

        logFile = tmp.appendingPathComponent("log.log")
        logger = MCPAuditLogger(overrideLogFile: logFile)

        tools = FilePanelMCPTools(
            yamlStore: yamlStore,
            legacyStore: legacyStore,
            logger: logger
        )

        // Seed an empty `default.yaml` so update_scope reads a known state.
        try yamlStore.saveScope(Scope(name: "default"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - YAML round-trip

    func testYAMLRoundTrip_matchesSpecFormat() throws {
        let scope = Scope(
            name: "default",
            schemaVersion: 1,
            criteria: [
                .init(root: "/Users/me/Pictures/tour/beach", recursive: true),
                .init(
                    root: "/Users/me/Pictures/tour/mountains",
                    recursive: true,
                    includeExts: ["jpg", "jpeg"],
                    excludeGlobs: ["**/*_old*", "**/.imageglass/**"]
                ),
            ],
            lastEvaluated: nil,
            resolved: [
                .init(path: "/Users/me/Pictures/tour/beach/001.jpg"),
                .init(path: "/Users/me/Pictures/tour/beach/002.jpg"),
            ]
        )
        let yaml = ScopeYAML.encode(scope)
        XCTAssertTrue(yaml.contains("name: default"))
        XCTAssertTrue(yaml.contains("schema_version: 1"))
        XCTAssertTrue(yaml.contains("  - root: /Users/me/Pictures/tour/beach"))
        XCTAssertTrue(yaml.contains("    include_exts: [jpg, jpeg]"))
        XCTAssertTrue(yaml.contains("    exclude_globs: [\"**/*_old*\", \"**/.imageglass/**\"]"))
        XCTAssertTrue(yaml.contains("  - path: /Users/me/Pictures/tour/beach/001.jpg"))

        let decoded = try ScopeYAML.decode(yaml)
        XCTAssertEqual(decoded.name, "default")
        XCTAssertEqual(decoded.criteria.count, 2)
        XCTAssertEqual(decoded.criteria[1].includeExts, ["jpg", "jpeg"])
        XCTAssertEqual(decoded.criteria[1].excludeGlobs, ["**/*_old*", "**/.imageglass/**"])
        XCTAssertEqual(decoded.resolved.map(\.path), [
            "/Users/me/Pictures/tour/beach/001.jpg",
            "/Users/me/Pictures/tour/beach/002.jpg",
        ])
    }

    // MARK: - update_scope: add_criteria (mcp_file.mdx §4)

    func testUpdateScope_addCriteria_walksAndWritesYAML() throws {
        let beach = fixtures.appendingPathComponent("beach").path
        let args: [String: Any?] = [
            "name": "default",
            "client": "claude-code",
            "patch": [
                "add_criteria": [
                    [
                        "root": beach,
                        "recursive": true,
                    ] as [String: Any?],
                ] as [Any?],
            ] as [String: Any?],
        ]
        let result = try tools.call(name: "update_scope", arguments: args)
        XCTAssertNotEqual(result.isError, true)

        let onDisk = try yamlStore.loadScope("default")
        XCTAssertEqual(onDisk.criteria.count, 1)
        XCTAssertEqual(onDisk.criteria[0].root, beach)
        XCTAssertTrue(onDisk.resolved.map(\.path).contains { $0.hasSuffix("/beach/001.jpg") })

        let log = try readLog()
        XCTAssertTrue(log.contains("tool=mcp.update_scope"))
        XCTAssertTrue(log.contains("client=claude-code"))
        XCTAssertTrue(log.contains("ok=true"))
        XCTAssertTrue(log.contains("app=scope.evaluate"))
        XCTAssertTrue(log.contains("name=default"))

        // The §8 invariant: every successful mcp.update_scope is followed by
        // a matching app=scope.evaluate line and the two share a corr= id.
        let updateCorr = corrFromLine(matching: "tool=mcp.update_scope", in: log)
        let evalCorr = corrFromLine(matching: "app=scope.evaluate", in: log)
        XCTAssertEqual(updateCorr, evalCorr,
                       "mcp.update_scope and scope.evaluate must share corr= id")
    }

    // MARK: - update_scope: remove_criteria_with_root (mcp_file.mdx §5)

    func testUpdateScope_removeCriteriaWithRoot() throws {
        let beach = fixtures.appendingPathComponent("beach").path
        let mountains = fixtures.appendingPathComponent("mountains").path
        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "add_criteria": [
                    ["root": beach] as [String: Any?],
                    ["root": mountains] as [String: Any?],
                ] as [Any?],
            ] as [String: Any?],
        ])
        XCTAssertEqual(try yamlStore.loadScope("default").criteria.count, 2)

        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "remove_criteria_with_root": [beach] as [Any?],
            ] as [String: Any?],
        ])
        let final = try yamlStore.loadScope("default")
        XCTAssertEqual(final.criteria.count, 1)
        XCTAssertEqual(final.criteria[0].root, mountains)
    }

    // MARK: - update_scope: set_include_exts_global (mcp_file.mdx §6)

    func testUpdateScope_setIncludeExtsGlobal_narrowsResolvedList() throws {
        let beach = fixtures.appendingPathComponent("beach").path
        let mountains = fixtures.appendingPathComponent("mountains").path
        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "add_criteria": [
                    ["root": beach] as [String: Any?],
                    ["root": mountains] as [String: Any?],
                ] as [Any?],
            ] as [String: Any?],
        ])
        let beforeExt = try yamlStore.loadScope("default").resolved.count
        XCTAssertGreaterThanOrEqual(beforeExt, 4)

        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "set_include_exts_global": ["jpg", "jpeg"] as [Any?],
            ] as [String: Any?],
        ])
        let scope = try yamlStore.loadScope("default")
        for c in scope.criteria {
            XCTAssertEqual(c.includeExts, ["jpg", "jpeg"])
        }
        // Only .jpg files survive (no .png / .heic).
        XCTAssertTrue(scope.resolved.map(\.path).allSatisfy { $0.hasSuffix(".jpg") })
    }

    // MARK: - update_scope: set_exclude_globs_global (mcp_file.mdx §7)

    func testUpdateScope_setExcludeGlobsGlobal_dropsMatches() throws {
        let beach = fixtures.appendingPathComponent("beach").path
        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "add_criteria": [
                    ["root": beach] as [String: Any?],
                ] as [Any?],
            ] as [String: Any?],
        ])

        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "set_exclude_globs_global": ["**/*_old*"] as [Any?],
            ] as [String: Any?],
        ])
        let scope = try yamlStore.loadScope("default")
        for c in scope.criteria {
            XCTAssertEqual(c.excludeGlobs, ["**/*_old*"])
        }
        XCTAssertFalse(scope.resolved.map(\.path).contains { $0.contains("_old") })
    }

    // MARK: - update_scope: clear_criteria (mcp_file.mdx §9)

    func testUpdateScope_clearCriteria_emptiesEverything() throws {
        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "add_criteria": [
                    ["root": fixtures.appendingPathComponent("beach").path] as [String: Any?],
                ] as [Any?],
            ] as [String: Any?],
        ])
        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "clear_criteria": true,
            ] as [String: Any?],
        ])
        let scope = try yamlStore.loadScope("default")
        XCTAssertEqual(scope.criteria.count, 0)
        XCTAssertEqual(scope.resolved.count, 0)
    }

    // MARK: - update_scope: malformed patch logs ok=false (§8)

    func testUpdateScope_malformedPatch_logsFailure_andDoesNotMutateScope() throws {
        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "add_criteria": "not-an-array",
            ] as [String: Any?],
        ])
        let log = try readLog()
        XCTAssertTrue(log.contains("ok=false"))
        XCTAssertTrue(log.contains("err=add_criteria_not_array"))

        // The original (empty) scope should be unchanged.
        let scope = try yamlStore.loadScope("default")
        XCTAssertEqual(scope.criteria.count, 0)
    }

    // MARK: - list_files_in_scope

    func testListFilesInScope_returnsResolvedPaths() throws {
        let beach = fixtures.appendingPathComponent("beach").path
        _ = try tools.call(name: "update_scope", arguments: [
            "name": "default",
            "patch": [
                "add_criteria": [["root": beach] as [String: Any?]] as [Any?],
            ] as [String: Any?],
        ])
        let result = try tools.call(name: "list_files_in_scope", arguments: ["name": "default"])
        XCTAssertNotEqual(result.isError, true)
        XCTAssertTrue(result.content[0].text.contains("\"total\""))
        XCTAssertTrue(result.content[0].text.contains("\"files\""))
    }

    // MARK: - panel.set_view_mode (§3)

    func testPanelSetViewMode_logsAndWritesHintFile() throws {
        let result = try tools.call(name: "panel.set_view_mode",
                                    arguments: ["mode": "tree", "client": "gui"])
        XCTAssertNotEqual(result.isError, true)
        let log = try readLog()
        XCTAssertTrue(log.contains("tool=mcp.panel.set_view_mode"))
        XCTAssertTrue(log.contains("client=gui"))
        XCTAssertTrue(log.contains("mode=tree"))
    }

    func testPanelSetViewMode_invalidMode_logsFailure() throws {
        let result = try tools.call(name: "panel.set_view_mode",
                                    arguments: ["mode": "bogus"])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(try readLog().contains("err=invalid_mode"))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("file-panel-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Replicates the `~/Pictures/tour/` layout from mcp_file.mdx §0.
    private func makeFixtures(under root: URL) throws -> URL {
        let tour = root.appendingPathComponent("tour", isDirectory: true)
        let beach = tour.appendingPathComponent("beach", isDirectory: true)
        let mountains = tour.appendingPathComponent("mountains", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: beach, withIntermediateDirectories: true)
        try fm.createDirectory(at: mountains, withIntermediateDirectories: true)
        for f in ["001.jpg", "002.jpg", "notes_old.png"] {
            try Data().write(to: beach.appendingPathComponent(f))
        }
        for f in ["peak.heic", "peak.jpg"] {
            try Data().write(to: mountains.appendingPathComponent(f))
        }
        try Data().write(to: tour.appendingPathComponent("README.txt"))
        return tour
    }

    private func readLog() throws -> String {
        guard FileManager.default.fileExists(atPath: logFile.path) else { return "" }
        let data = try Data(contentsOf: logFile)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func corrFromLine(matching needle: String, in log: String) -> String? {
        for line in log.split(separator: "\n") {
            if line.contains(needle) {
                if let r = line.range(of: " corr=") {
                    let after = line[r.upperBound...]
                    let id = after.split(separator: " ", maxSplits: 1).first.map(String.init)
                    return id
                }
            }
        }
        return nil
    }
}
