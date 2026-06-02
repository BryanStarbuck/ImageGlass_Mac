import XCTest
@testable import ImageGlassCore

/// Hardening tests for `MCPTools` that exercise the spec's stricter
/// requirements: scope-name validation, path normalization, idempotent
/// delete, isError-style failures, and concurrency safety under the
/// process-local lock (§8).
final class MCPToolsHardeningTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpHome.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        if let h = originalHome { setenv("HOME", h, 1) }
    }

    // MARK: - get_scope

    func testGetScopeReturnsIsErrorOnUnknown() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "get_scope", arguments: ["name": "nope"])
        XCTAssertTrue(r.isError ?? false)
        XCTAssertTrue(r.content.first?.text.contains("Unknown scope") ?? false)
    }

    func testGetScopeRejectsInvalidName() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "get_scope", arguments: ["name": "../etc"])
        XCTAssertTrue(r.isError ?? false)
        XCTAssertTrue(r.content.first?.text.contains("Invalid scope name") ?? false)
    }

    // MARK: - create_scope name validation

    func testCreateRejectsSlashInName() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "create_scope", arguments: ["name": "a/b"])
        XCTAssertTrue(r.isError ?? false)
    }

    func testCreateRejectsLeadingDot() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "create_scope", arguments: ["name": ".hidden"])
        XCTAssertTrue(r.isError ?? false)
    }

    func testCreateRejectsEmpty() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "create_scope", arguments: ["name": ""])
        XCTAssertTrue(r.isError ?? false)
    }

    // MARK: - create_scope normalizes paths

    func testCreateNormalizesTildePaths() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "tilde-test",
            "directories": ["~/Pictures"] as [Any?],
        ])
        let scope = try LocalStorage.shared.loadScope("tilde-test")
        XCTAssertEqual(scope.include.directories, ["~/Pictures"])
    }

    func testCreateNormalizesAbsolutePaths() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "abs-test",
            "directories": ["/tmp/foo/../bar"] as [Any?],
        ])
        let scope = try LocalStorage.shared.loadScope("abs-test")
        XCTAssertEqual(scope.include.directories, ["/tmp/bar"])
    }

    func testCreateDeduplicatesDirectories() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "dedup",
            "directories": ["/tmp/a", "/tmp/a", "/tmp/b"] as [Any?],
        ])
        let scope = try LocalStorage.shared.loadScope("dedup")
        XCTAssertEqual(scope.include.directories, ["/tmp/a", "/tmp/b"])
    }

    // MARK: - set_directories normalizes paths

    func testSetDirectoriesNormalizes() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "norm"])
        _ = try tools.call(name: "set_directories", arguments: [
            "name": "norm",
            "directories": ["~/Pictures", "/tmp/x/../y"] as [Any?],
        ])
        let scope = try LocalStorage.shared.loadScope("norm")
        XCTAssertEqual(scope.include.directories, ["~/Pictures", "/tmp/y"])
    }

    func testSetDirectoriesAlsoUpdatesRecursive() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "rec"])
        _ = try tools.call(name: "set_directories", arguments: [
            "name": "rec",
            "directories": ["/tmp/x"] as [Any?],
            "recursive": false,
        ])
        let scope = try LocalStorage.shared.loadScope("rec")
        XCTAssertEqual(scope.include.recursive, false)
    }

    func testSetDirectoriesOnUnknownScopeIsError() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "set_directories", arguments: [
            "name": "nope",
            "directories": ["/tmp"] as [Any?],
        ])
        XCTAssertTrue(r.isError ?? false)
    }

    // MARK: - set_include_criteria / set_exclude_criteria partial updates

    func testSetIncludeCriteriaIsPartialUpdate() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "part",
            "extensions": ["png"] as [Any?],
            "include_globs": ["IMG_*"] as [Any?],
        ])
        // Only update globs; extensions should remain.
        _ = try tools.call(name: "set_include_criteria", arguments: [
            "name": "part",
            "globs": ["new_*"] as [Any?],
        ])
        let scope = try LocalStorage.shared.loadScope("part")
        XCTAssertEqual(scope.include.globs, ["new_*"])
        XCTAssertEqual(scope.include.extensions, ["png"])
    }

    func testSetExcludeCriteriaHiddenOnly() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "ex",
            "exclude_globs": ["*_old*"] as [Any?],
        ])
        _ = try tools.call(name: "set_exclude_criteria", arguments: [
            "name": "ex",
            "hidden_files": false,
        ])
        let scope = try LocalStorage.shared.loadScope("ex")
        XCTAssertEqual(scope.exclude.hiddenFiles, false)
        XCTAssertEqual(scope.exclude.globs, ["*_old*"])
    }

    // MARK: - delete_scope idempotency

    func testDeleteScopeIdempotent() throws {
        let tools = MCPTools()
        let r = try tools.call(name: "delete_scope", arguments: ["name": "never-existed"])
        // Spec §9: "deleting a non-existent scope is reported as such but is not an error."
        XCTAssertFalse(r.isError ?? false)
        XCTAssertTrue(r.content.first?.text.contains("did not exist") ?? false)
    }

    func testDeleteScopeRemovesExisting() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "to-delete"])
        XCTAssertTrue(LocalStorage.shared.scopeExists("to-delete"))
        let r = try tools.call(name: "delete_scope", arguments: ["name": "to-delete"])
        XCTAssertFalse(r.isError ?? false)
        XCTAssertFalse(LocalStorage.shared.scopeExists("to-delete"))
    }

    // MARK: - evaluate_scope re-reads from disk and writes back

    func testEvaluateScopePersistsAndReturnsResolvedList() throws {
        let dir = tmpHome.appendingPathComponent("imgs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.png"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("b.png"))

        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "evalme",
            "directories": [dir.path] as [Any?],
            "extensions": ["png"] as [Any?],
        ])
        let r = try tools.call(name: "evaluate_scope", arguments: ["name": "evalme"])
        XCTAssertFalse(r.isError ?? false)
        let text = r.content.first?.text ?? ""
        XCTAssertTrue(text.contains("\"fileCount\" : 2"))

        let reloaded = try LocalStorage.shared.loadScope("evalme")
        XCTAssertNotNil(reloaded.lastEvaluated)
        XCTAssertEqual(reloaded.resolvedFiles.count, 2)
    }

    // MARK: - Concurrency under MCPLock (spec §8)

    func testConcurrentCreatesAreSerialized() throws {
        // Spec §8: "Two concurrent tool calls cannot corrupt the YAML files."
        // We fire many parallel create_scope calls under a shared lock; the
        // serialized writes must each land on disk and be readable.
        let tools = MCPTools()
        let count = 32
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ig.test.concurrent", attributes: .concurrent)

        for i in 0..<count {
            group.enter()
            queue.async {
                _ = try? tools.call(name: "create_scope", arguments: [
                    "name": "concurrent_\(i)",
                ])
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let listed = try LocalStorage.shared.listScopes()
        let createdSet = Set(listed.filter { $0.hasPrefix("concurrent_") })
        XCTAssertEqual(createdSet.count, count)
    }

    // MARK: - set_criteria (multi-criteria, spec §3.1)

    func testSetCriteriaReplacesAll() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "mc"])
        _ = try tools.call(name: "set_criteria", arguments: [
            "name": "mc",
            "criteria": [
                [
                    "root": "~/Pictures",
                    "recursive": true,
                    "include_exts": ["jpg", "png"] as [Any?],
                    "exclude_globs": ["**/_archive/**"] as [Any?],
                    "include_hidden": false,
                    "max_depth": 3,
                ] as [String: Any?],
                [
                    "root": "/tmp/extra",
                    "recursive": false,
                    "include_exts": ["heic"] as [Any?],
                ] as [String: Any?],
            ] as [Any?],
        ])
        let scope = try LocalStorage.shared.loadScope("mc")
        XCTAssertEqual(scope.criteria.count, 2)
        XCTAssertEqual(scope.criteria[0].includeExts, ["jpg", "png"])
        XCTAssertEqual(scope.criteria[0].excludeGlobs, ["**/_archive/**"])
        XCTAssertEqual(scope.criteria[0].maxDepth, 3)
        XCTAssertEqual(scope.criteria[1].root, "/tmp/extra")
        XCTAssertEqual(scope.criteria[1].recursive, false)
    }

    // MARK: - set_sort / set_filter persistence (spec §3.1)

    func testSetSortPersists() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "s"])
        _ = try tools.call(name: "set_sort", arguments: [
            "name": "s",
            "by": "modified",
            "direction": "desc",
        ])
        let scope = try LocalStorage.shared.loadScope("s")
        XCTAssertEqual(scope.sort.by, .modified)
        XCTAssertEqual(scope.sort.direction, .desc)
    }

    func testSetFilterPersists() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "f"])
        _ = try tools.call(name: "set_filter", arguments: [
            "name": "f",
            "text": "sunset",
            "min_width": 3000,
            "max_size": 5_000_000,
        ])
        let scope = try LocalStorage.shared.loadScope("f")
        XCTAssertEqual(scope.filter.text, "sunset")
        XCTAssertEqual(scope.filter.minWidth, 3000)
        XCTAssertEqual(scope.filter.maxSize, 5_000_000)
    }

    // MARK: - schema_version stamped on disk (spec §3.1)

    func testCreatedScopeWritesSchemaVersion() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "sv"])
        let data = try Data(contentsOf: LocalStorage.shared.scopeURL(for: "sv"))
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"schema_version\""), "expected schema_version in: \(text)")
    }

    // MARK: - resolved schema on disk has per-file metadata (spec §3.1)

    func testEvaluatedScopeWritesResolvedWithMetadata() throws {
        let dir = tmpHome.appendingPathComponent("imgs2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.png"))

        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "rsv",
            "directories": [dir.path] as [Any?],
            "extensions": ["png"] as [Any?],
        ])
        _ = try tools.call(name: "evaluate_scope", arguments: ["name": "rsv"])

        let scope = try LocalStorage.shared.loadScope("rsv")
        XCTAssertEqual(scope.resolved.count, 1)
        XCTAssertNotNil(scope.resolved[0].size)
        XCTAssertNotNil(scope.resolved[0].modified)
    }

    func testConcurrentEditsOnSameScopeProduceValidYAML() throws {
        // Multiple set_include_criteria calls on the same scope in parallel
        // must not lose the scope file. Whatever the last writer wins, the
        // file must be valid and re-loadable.
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "race"])

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "ig.test.race", attributes: .concurrent)
        for i in 0..<32 {
            group.enter()
            queue.async {
                _ = try? tools.call(name: "set_include_criteria", arguments: [
                    "name": "race",
                    "extensions": ["ext\(i)"] as [Any?],
                ])
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        // File must still be a valid scope. The exact winner is not asserted —
        // only durability is.
        XCTAssertNoThrow(try LocalStorage.shared.loadScope("race"))
    }
}
