import XCTest
@testable import ImageGlassCore

/// Smoke tests for the directory-tree MCP tools introduced by
/// `docs/use_cases/mcp_file.mdx`. Covers the happy paths in §4 / §5 /
/// §6 / §7 / §9 from the use case tour. The tour's "verify" steps are
/// `cat directories.yaml` and `grep log.log`; these tests do the same.
final class DirectoriesMCPToolsTests: XCTestCase {

    var tmpDir: URL!
    var dirsFile: URL!
    var logFile: URL!
    var store: DirectoriesStore!
    var logger: MCPAuditLogger!
    var tools: DirectoriesMCPTools!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp_tools_tests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        dirsFile = tmpDir.appendingPathComponent("directories.yaml")
        logFile = tmpDir.appendingPathComponent("log.log")
        store = DirectoriesStore(overrideFile: dirsFile)
        logger = MCPAuditLogger(overrideLogFile: logFile)
        tools = DirectoriesMCPTools(
            store: store,
            logger: logger,
            walker: DirectoryTreeWalker(store: store, logger: logger)
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // §4: add_directory writes path + empty filter to directories.yaml.
    func testAddDirectoryWritesYAML() throws {
        let fixture = tmpDir.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        _ = try tools.call(name: "add_directory", arguments: ["path": fixture.path])
        let yaml = try String(contentsOf: dirsFile)
        XCTAssertTrue(yaml.contains("schema_version: 1"))
        XCTAssertTrue(yaml.contains("root_directories:"))
        XCTAssertTrue(yaml.contains(fixture.path))
        XCTAssertTrue(yaml.contains("items: []"))
    }

    // §4.4 + §8: every successful add emits `tool=mcp.add_directory … ok=true`.
    func testAddDirectoryEmitsAuditLine() throws {
        let fixture = tmpDir.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        _ = try tools.call(name: "add_directory", arguments: ["path": fixture.path])
        let log = try String(contentsOf: logFile)
        XCTAssertTrue(log.contains("tool=mcp.add_directory"))
        XCTAssertTrue(log.contains("ok=true"))
        XCTAssertTrue(log.contains(fixture.path))
    }

    // §4.3: add_directory on an existing root returns already_exists, no
    // duplicate entry on disk.
    func testAddDirectoryIsIdempotent() throws {
        let fixture = tmpDir.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        _ = try tools.call(name: "add_directory", arguments: ["path": fixture.path])
        _ = try tools.call(name: "add_directory", arguments: ["path": fixture.path])
        let loaded = try store.load()
        XCTAssertEqual(loaded.roots.count, 1)
    }

    // §5: remove_directory drops the entry and emits a `mcp.remove_directory` line.
    func testRemoveDirectory() throws {
        let fixture = tmpDir.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        _ = try tools.call(name: "add_directory", arguments: ["path": fixture.path])
        _ = try tools.call(name: "remove_directory", arguments: ["path": fixture.path])
        let loaded = try store.load()
        XCTAssertEqual(loaded.roots.count, 0)
        let log = try String(contentsOf: logFile)
        XCTAssertTrue(log.contains("tool=mcp.remove_directory"))
    }

    // §6: set_global_filter applies the same filter to every existing
    // root and emits the `app=directory.refilter` line.
    func testSetGlobalFilter() throws {
        let beach = tmpDir.appendingPathComponent("beach")
        let mountains = tmpDir.appendingPathComponent("mountains")
        for d in [beach, mountains] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            _ = try tools.call(name: "add_directory", arguments: ["path": d.path])
        }
        _ = try tools.call(name: "set_global_filter", arguments: [
            "filter": [
                "match": "any",
                "items": [
                    ["pattern": "*.jpg"],
                    ["pattern": "*.jpeg"],
                ] as [Any],
            ] as [String: Any],
        ])
        let loaded = try store.load()
        for r in loaded.roots {
            XCTAssertEqual(r.filter.items.count, 2)
            XCTAssertEqual(r.filter.items.first?.pattern, "*.jpg")
        }
        let log = try String(contentsOf: logFile)
        XCTAssertTrue(log.contains("tool=mcp.set_global_filter"))
        XCTAssertTrue(log.contains("app=directory.refilter"))
    }

    // §7: update_directory_filter replaces one root's filter, supports
    // `negate: true` items, and records `negate_items=N`.
    func testUpdateDirectoryFilterWithNegate() throws {
        let beach = tmpDir.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: beach, withIntermediateDirectories: true)
        _ = try tools.call(name: "add_directory", arguments: ["path": beach.path])
        _ = try tools.call(name: "update_directory_filter", arguments: [
            "path": beach.path,
            "filter": [
                "match": "any",
                "items": [
                    ["pattern": "*.jpg"],
                    ["pattern": "*_old*", "negate": true] as [String: Any],
                ] as [Any],
            ] as [String: Any],
        ])
        let loaded = try store.load()
        let filter = loaded.roots.first!.filter
        XCTAssertEqual(filter.items.count, 2)
        XCTAssertTrue(filter.items.contains { $0.pattern == "*_old*" && $0.negate })
        let log = try String(contentsOf: logFile)
        XCTAssertTrue(log.contains("negate_items=1"))
    }

    // §9: clear_directories empties root_directories[] on disk.
    func testClearDirectories() throws {
        let beach = tmpDir.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: beach, withIntermediateDirectories: true)
        _ = try tools.call(name: "add_directory", arguments: ["path": beach.path])
        _ = try tools.call(name: "clear_directories", arguments: [:])
        let loaded = try store.load()
        XCTAssertEqual(loaded.roots.count, 0)
        let yaml = try String(contentsOf: dirsFile)
        XCTAssertTrue(yaml.contains("root_directories: []"))
    }

    // §9: list_directories returns the empty array when there are no
    // roots — and a populated array after add_directory.
    func testListDirectories() throws {
        let beach = tmpDir.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: beach, withIntermediateDirectories: true)
        var result = try tools.call(name: "list_directories", arguments: [:])
        XCTAssertTrue(result.content.first!.text.contains("[]"))
        _ = try tools.call(name: "add_directory", arguments: ["path": beach.path])
        result = try tools.call(name: "list_directories", arguments: [:])
        XCTAssertTrue(result.content.first!.text.contains(beach.path))
    }

    // §4.3 + §10: missing path argument returns ok=false err=missing_path
    // and does NOT mutate directories.yaml.
    func testInvalidCallEmitsErrAndDoesNotMutate() throws {
        let result = try tools.call(name: "add_directory", arguments: [:])
        XCTAssertEqual(result.isError, true)
        let log = try String(contentsOf: logFile)
        XCTAssertTrue(log.contains("ok=false"))
        XCTAssertTrue(log.contains("err=missing_path"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirsFile.path),
                       "directories.yaml must not be created by a failed call")
    }

    // §3A.3: walker drops files that aren't image / svg / video.
    func testWalkerBuiltinFileKindFilter() throws {
        let beach = tmpDir.appendingPathComponent("beach")
        try FileManager.default.createDirectory(at: beach, withIntermediateDirectories: true)
        try Data().write(to: beach.appendingPathComponent("a.jpg"))
        try Data().write(to: beach.appendingPathComponent("b.heic"))
        try Data().write(to: beach.appendingPathComponent("README.txt"))
        let result = DirectoryTreeWalker.walkSync(root: beach, filter: .empty)
        XCTAssertEqual(result.fileCount, 2, "README.txt should be dropped")
        XCTAssertNotNil(result.firstImage)
        XCTAssertEqual(result.firstImage!.lastPathComponent, "a.jpg")
    }

    // MARK: - §7.0 / §10B — negative-filter mental model and cookbook

    // §7.0 / §3A.7: a single `negate: true` item with no positive items
    // means "everything except the negate matches" — the special case
    // that makes "show everything except X" a one-item filter.
    func testNegateOnlyFilterCarvesOut() {
        let f = RootFilter(items: [
            RootFilterItem(pattern: "*_DM_*", kind: .glob, negate: true)
        ])
        XCTAssertTrue(f.evaluate(filename: "frame_42.jpg"))
        XCTAssertTrue(f.evaluate(filename: "peak.heic"))
        XCTAssertFalse(f.evaluate(filename: "frame_42_DM_1.jpg"),
                       "files matching the single negate must be excluded")
    }

    // §7.0 veto semantic: even when a positive item matches, a negate
    // match still excludes.
    func testNegateVetoesPositiveMatch() {
        let f = RootFilter(items: [
            RootFilterItem(pattern: "*.png", kind: .glob),
            RootFilterItem(pattern: "*_old*", kind: .glob, negate: true),
        ])
        XCTAssertTrue(f.evaluate(filename: "image.png"))
        XCTAssertFalse(f.evaluate(filename: "notes_old.png"),
                       "negate must veto matching positives (mcp_file.mdx §7)")
        XCTAssertFalse(f.evaluate(filename: "raw.jpg"),
                       "files that don't match any positive are still excluded")
    }

    // §10B canonical: the JFK/UX + `_DM_` negative-filter rehearsal.
    // The MCP call returns ok=true, the YAML stores the regex form +
    // `negate: true`, the log records `negate_items=1`, and the
    // refilter call emits `app=directory.refilter` with the same corr
    // id as the `tool=mcp.update_directory_filter` line — no paired
    // `app=directory.walk` line shares that corr id (§3A.7: filter
    // changes are in-memory only).
    func testJFKUXNegativeDMFilterRehearsal() throws {
        let root = tmpDir.appendingPathComponent("JFK_UX")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try tools.call(name: "add_directory", arguments: ["path": root.path])

        _ = try tools.call(name: "update_directory_filter", arguments: [
            "path": root.path,
            "filter": [
                "match": "any",
                "items": [
                    [
                        "pattern": ".*_DM_.*\\.jpg$",
                        "kind": "regex",
                        "negate": true,
                    ] as [String: Any],
                ] as [Any],
            ] as [String: Any],
        ])

        let yaml = try String(contentsOf: dirsFile)
        XCTAssertTrue(yaml.contains(".*_DM_.*\\.jpg$"),
                      "yaml must store the canonical regex form (§10B.4)")
        XCTAssertTrue(yaml.contains("kind: regex"))
        XCTAssertTrue(yaml.contains("negate: true"))

        let log = try String(contentsOf: logFile)

        // Find the corr= id from the update_directory_filter line and
        // verify the paired refilter line carries the same id but no
        // directory.walk line does. This is the §10B.6 contract: filter
        // changes don't walk the filesystem.
        let updateLine = log.split(separator: "\n").first {
            $0.contains("tool=mcp.update_directory_filter") && $0.contains("ok=true")
        }
        XCTAssertNotNil(updateLine, "update_directory_filter must journal an ok=true line")
        guard let line = updateLine,
              let corrRange = line.range(of: #"corr=([0-9a-f]+)"#, options: .regularExpression) else {
            return XCTFail("update line missing a corr= field")
        }
        let corr = String(line[corrRange]).replacingOccurrences(of: "corr=", with: "")

        XCTAssertTrue(
            log.split(separator: "\n").contains {
                $0.contains("app=directory.refilter") && $0.contains("corr=\(corr)")
            },
            "the refilter call must emit an app=directory.refilter line with the same corr id (§10B.6)"
        )
        XCTAssertFalse(
            log.split(separator: "\n").contains {
                $0.contains("app=directory.walk") && $0.contains("corr=\(corr)")
            },
            "no app=directory.walk line shares the refilter call's corr id (§3A.7)"
        )
        XCTAssertTrue(log.contains("negate_items=1"),
                      "§10B.6 audit must carry negate_items=1")
    }

    // §10B.1: the `.../` recursive-prefix shorthand is stripped at the
    // MCP boundary and never lands in directories.yaml.
    func testDotDotDotSlashPrefixIsStripped() throws {
        let parsed = try DirectoriesMCPTools.parseFilterDict([
            "items": [
                ["pattern": ".../*_DM_*.jpg"] as [String: Any?],
            ] as [Any?],
        ])
        XCTAssertEqual(parsed.items.first?.pattern, "*_DM_*.jpg",
                       "`.../` prefix is implicit and must be stripped (§10B.1)")
    }

    // §10B.9: an invalid regex surfaces at parse time (not silently at
    // evaluate time), and the MCP audit line records err=invalid_regex.
    func testInvalidRegexFails() throws {
        let result = try tools.call(name: "set_global_filter", arguments: [
            "filter": [
                "items": [
                    ["pattern": ".*_DM_(.*\\.jpg$", "kind": "regex"] as [String: Any]
                ] as [Any],
            ] as [String: Any],
        ])
        XCTAssertEqual(result.isError, true)
        let log = try String(contentsOf: logFile)
        XCTAssertTrue(log.contains("err=invalid_regex"),
                      "audit must distinguish invalid_regex from generic invalid_filter (§10B.9)")
    }

    // §10B.9 / §10B.8: a path-separator pattern (after `.../` stripping)
    // returns err=path_separator_in_pattern; v1 supports filename
    // matching only.
    func testPathSeparatorInPatternRejected() throws {
        let result = try tools.call(name: "set_global_filter", arguments: [
            "filter": [
                "items": [
                    ["pattern": "*/foo/*_DM_*.jpg"] as [String: Any]
                ] as [Any],
            ] as [String: Any],
        ])
        XCTAssertEqual(result.isError, true)
        let log = try String(contentsOf: logFile)
        XCTAssertTrue(log.contains("err=path_separator_in_pattern"),
                      "§10B.9 audit code must surface to the log")
    }

    // §7.0.1 cookbook row: stacking two `negate: true` items means
    // either match excludes. Both `_DM_` and `_WIP_` files disappear.
    func testStackedNegatesCookbookRow() {
        let f = RootFilter(items: [
            RootFilterItem(pattern: "*_DM_*",  kind: .glob, negate: true),
            RootFilterItem(pattern: "*_WIP_*", kind: .glob, negate: true),
        ])
        XCTAssertTrue(f.evaluate(filename: "frame_42.jpg"))
        XCTAssertFalse(f.evaluate(filename: "frame_42_DM_1.jpg"))
        XCTAssertFalse(f.evaluate(filename: "frame_42_WIP_1.jpg"))
    }

    // §7.0.1 cookbook row: regex variant matching `_DM_` JPEGs only
    // (PNGs still visible).
    func testRegexNegateNarrowsToJpegOnly() {
        let f = RootFilter(items: [
            RootFilterItem(pattern: ".*_DM_.*\\.jpg$", kind: .regex, negate: true)
        ])
        XCTAssertTrue(f.evaluate(filename: "frame_DM_1.png"),
                      "PNG variant of the marker stays visible per cookbook row")
        XCTAssertFalse(f.evaluate(filename: "frame_DM_1.jpg"))
    }
}
