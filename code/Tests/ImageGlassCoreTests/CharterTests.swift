import XCTest
@testable import ImageGlassCore

/// Coverage for the charter additions: ScopeDiff, RuleSet, ScopeChain,
/// audit log, scope import/export, and the MCP tools that surface them.
final class CharterTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?

    override func setUpWithError() throws {
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-charter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpHome.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        if let h = originalHome { setenv("HOME", h, 1) }
    }

    // MARK: - ScopeDiff

    func testScopeDiffBetween() {
        let prev = ["~/a.png", "~/b.png", "~/c.png"]
        let curr = ["~/b.png", "~/c.png", "~/d.png"]
        let diff = ScopeDiff.between(previous: prev, current: curr)
        XCTAssertEqual(diff.added, ["~/d.png"])
        XCTAssertEqual(diff.removed, ["~/a.png"])
        XCTAssertEqual(diff.previousCount, 3)
        XCTAssertEqual(diff.currentCount, 3)
        XCTAssertFalse(diff.isEmpty)
    }

    func testScopeDiffEmptyWhenEqual() {
        let xs = ["a", "b"]
        XCTAssertTrue(ScopeDiff.between(previous: xs, current: xs).isEmpty)
    }

    // MARK: - RuleSet on-disk storage (plain text JSON)

    func testRuleSetRoundTripsAsPlainTextJSON() throws {
        let rs = RuleSet(
            name: "web_screens",
            description: "Web screenshots only",
            include: .init(directories: [], recursive: true, extensions: ["png", "webp"]),
            exclude: .init(globs: ["*_old*"], hiddenFiles: true)
        )
        try RuleSetStorage.shared.saveRuleSet(rs)
        XCTAssertTrue(RuleSetStorage.shared.ruleSetExists("web_screens"))

        // Plain-text guarantee: the on-disk file must be readable as UTF-8
        // JSON, never a binary blob.
        let url = RuleSetStorage.shared.ruleSetURL(for: "web_screens")
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"name\""))
        XCTAssertTrue(raw.contains("web_screens"))
        XCTAssertTrue(raw.contains("\"extensions\""))

        let loaded = try RuleSetStorage.shared.loadRuleSet("web_screens")
        XCTAssertEqual(loaded, rs)

        let listed = try RuleSetStorage.shared.listRuleSets()
        XCTAssertEqual(listed, ["web_screens"])

        try RuleSetStorage.shared.deleteRuleSet("web_screens")
        XCTAssertFalse(RuleSetStorage.shared.ruleSetExists("web_screens"))
    }

    // MARK: - ScopeChain composition

    func testRuleSetIsMergedIntoScope() throws {
        try RuleSetStorage.shared.saveRuleSet(RuleSet(
            name: "imgs",
            include: .init(directories: [], recursive: false, extensions: ["png"]),
            exclude: .init(globs: ["*_old*"], hiddenFiles: false)
        ))
        let scope = Scope(
            name: "main",
            include: .init(directories: ["~/Pictures"], recursive: false, extensions: ["jpg"]),
            ruleSets: ["imgs"]
        )
        let eff = ScopeChain.compose(scope)
        XCTAssertTrue(eff.include.extensions.contains("png"))
        XCTAssertTrue(eff.include.extensions.contains("jpg"))
        XCTAssertTrue(eff.exclude.globs.contains("*_old*"))
        XCTAssertTrue(eff.sources.contains("ruleset:imgs"))
        XCTAssertTrue(eff.sources.contains("scope:main"))
    }

    func testInheritsFromComposesDirectories() throws {
        let parent = Scope(
            name: "parent",
            include: .init(directories: ["~/parent_dir"], recursive: false, extensions: ["png"])
        )
        try LocalStorage.shared.saveScope(parent)
        let child = Scope(
            name: "child",
            include: .init(directories: ["~/child_dir"], recursive: false, extensions: ["jpg"]),
            inheritsFrom: ["parent"]
        )
        let eff = ScopeChain.compose(child)
        XCTAssertEqual(Set(eff.include.directories), Set(["~/parent_dir", "~/child_dir"]))
        XCTAssertEqual(Set(eff.include.extensions), Set(["png", "jpg"]))
    }

    func testInheritsFromCycleIsSafe() throws {
        // a -> b -> a
        let a = Scope(name: "a",
                      include: .init(directories: ["~/a_dir"], recursive: false),
                      inheritsFrom: ["b"])
        let b = Scope(name: "b",
                      include: .init(directories: ["~/b_dir"], recursive: false),
                      inheritsFrom: ["a"])
        try LocalStorage.shared.saveScope(a)
        try LocalStorage.shared.saveScope(b)
        let eff = ScopeChain.compose(a)
        // Must terminate without infinite recursion and surface both dirs.
        XCTAssertEqual(Set(eff.include.directories), Set(["~/a_dir", "~/b_dir"]))
    }

    func testRecursiveIsAnyTrueWins() {
        let scope = Scope(
            name: "x",
            include: .init(directories: [], recursive: false, extensions: ["png"])
        )
        try? RuleSetStorage.shared.saveRuleSet(RuleSet(
            name: "rec",
            include: .init(directories: [], recursive: true, extensions: ["jpg"])
        ))
        var withRS = scope
        withRS.ruleSets = ["rec"]
        let eff = ScopeChain.compose(withRS)
        XCTAssertTrue(eff.include.recursive, "any-true wins for recursion")
    }

    // MARK: - Audit log

    func testAuditLogAppendsAndTails() throws {
        let log = ScopeAuditLog.shared
        try log.append(ScopeAuditEntry(timestamp: Date(), fileCount: 3, added: ["x.png"], removed: []), scopeName: "s")
        try log.append(ScopeAuditEntry(timestamp: Date(), fileCount: 4, added: ["y.png"], removed: []), scopeName: "s")
        let entries = try log.tail(scopeName: "s", limit: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.fileCount, 4)
        XCTAssertEqual(entries.first?.added, ["x.png"])

        // Audit file is JSONL (plain text, one entry per line).
        let url = log.logURL(for: "s")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)

        // Clearing wipes the file.
        try log.clear(scopeName: "s")
        XCTAssertEqual(try log.tail(scopeName: "s").count, 0)
    }

    // MARK: - ScopeEvaluator.evaluateWithProvenance

    func testEvaluateWithProvenancePopulatesDiffAndAuditLog() throws {
        let dir = tmpHome.appendingPathComponent("pics", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.png"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("b.png"))

        var scope = Scope(
            name: "prov",
            include: .init(directories: [dir.path], recursive: false, extensions: ["png"])
        )

        // First pass — no prior list, so diff (added: 2, removed: 0) but
        // current logic stores nil if isEmpty; here it's non-empty.
        scope = ScopeEvaluator.evaluateWithProvenance(scope)
        XCTAssertEqual(scope.resolvedFiles.count, 2)
        XCTAssertNotNil(scope.lastDiff)
        XCTAssertEqual(scope.lastDiff?.added.count, 2)
        XCTAssertEqual(scope.lastDiff?.removed.count, 0)

        // Second pass with an added file.
        try Data("x".utf8).write(to: dir.appendingPathComponent("c.png"))
        scope = ScopeEvaluator.evaluateWithProvenance(scope)
        XCTAssertEqual(scope.resolvedFiles.count, 3)
        XCTAssertEqual(scope.lastDiff?.added.count, 1)
        XCTAssertEqual(scope.lastDiff?.removed.count, 0)

        // Audit log contains both runs.
        let entries = try ScopeAuditLog.shared.tail(scopeName: "prov", limit: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.fileCount, 3)
    }

    // MARK: - Scope import / export

    func testScopeBundleRoundTrip() throws {
        try RuleSetStorage.shared.saveRuleSet(RuleSet(
            name: "rs1",
            include: .init(directories: [], recursive: true, extensions: ["png"])
        ))
        let scope = Scope(
            name: "shareable",
            include: .init(directories: ["~/Pictures"], recursive: true),
            ruleSets: ["rs1"]
        )
        try LocalStorage.shared.saveScope(scope)

        let bundle = try ScopeBundleService.export(scopeName: "shareable")
        XCTAssertEqual(bundle.scope.name, "shareable")
        XCTAssertEqual(bundle.ruleSets.map { $0.name }, ["rs1"])
        let json = try ScopeBundleService.encodeJSON(bundle)
        XCTAssertTrue(json.contains("\"shareable\""))
        XCTAssertTrue(json.contains("\"rs1\""))

        // Decode and re-install into a clean store.
        try LocalStorage.shared.deleteScope("shareable")
        try RuleSetStorage.shared.deleteRuleSet("rs1")
        let decoded = try ScopeBundleService.decodeJSON(json)
        let installed = try ScopeBundleService.install(decoded)
        XCTAssertEqual(installed.name, "shareable")
        XCTAssertTrue(LocalStorage.shared.scopeExists("shareable"))
        XCTAssertTrue(RuleSetStorage.shared.ruleSetExists("rs1"))
    }

    func testScopeBundleRefusesDuplicateWithoutOverwrite() throws {
        let scope = Scope(name: "dup-bundle")
        try LocalStorage.shared.saveScope(scope)
        let bundle = ScopeBundle(scope: scope)
        XCTAssertThrowsError(try ScopeBundleService.install(bundle, overwrite: false))
        XCTAssertNoThrow(try ScopeBundleService.install(bundle, overwrite: true))
    }

    // MARK: - Legacy compatibility

    func testLegacyScopeJSONDecodesWithoutCharterFields() throws {
        // A scope file written by the pre-charter scaffold has no
        // `inheritsFrom` / `ruleSets` / `lastDiff` keys. It must still decode
        // cleanly so existing user data is never broken.
        let legacy = """
        {
          "exclude": { "globs": [], "hiddenFiles": true },
          "include": { "directories": ["~/Pictures"], "extensions": ["png"], "globs": [], "recursive": true },
          "name": "legacy",
          "resolvedFiles": []
        }
        """
        let url = LocalStorage.shared.scopeURL(for: "legacy")
        try AppPaths.ensureDirectories()
        try legacy.data(using: .utf8)!.write(to: url)
        let scope = try LocalStorage.shared.loadScope("legacy")
        XCTAssertEqual(scope.name, "legacy")
        XCTAssertNil(scope.inheritsFrom)
        XCTAssertNil(scope.ruleSets)
        XCTAssertNil(scope.lastDiff)
    }

    // MARK: - MCP tool wiring

    func testMCPCharterToolsAdvertised() {
        let tools = MCPTools()
        let names = Set(tools.descriptors().map { $0.name })
        for expected in [
            "list_rule_sets", "create_rule_set", "delete_rule_set",
            "attach_rule_set", "detach_rule_set", "get_rule_set",
            "set_inheritance", "get_effective_rules",
            "get_audit_log", "get_last_diff",
            "export_scope", "import_scope",
        ] {
            XCTAssertTrue(names.contains(expected), "MCP should advertise \(expected)")
        }
    }

    func testMCPCreateRuleSetAttachAndEffectiveRules() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "ms"])
        _ = try tools.call(name: "create_rule_set", arguments: [
            "name": "rs",
            "extensions": ["png"] as [Any?],
            "exclude_globs": ["*_old*"] as [Any?],
        ])
        _ = try tools.call(name: "attach_rule_set", arguments: [
            "scope": "ms", "rule_set": "rs",
        ])
        let scope = try LocalStorage.shared.loadScope("ms")
        XCTAssertEqual(scope.ruleSets, ["rs"])

        let effective = try tools.call(name: "get_effective_rules", arguments: ["name": "ms"])
        XCTAssertFalse(effective.isError ?? false)
        let text = effective.content.first?.text ?? ""
        XCTAssertTrue(text.contains("\"png\""))
        XCTAssertTrue(text.contains("\"*_old*\""))
        XCTAssertTrue(text.contains("ruleset:rs"))
    }

    func testMCPEvaluateRecordsDiffAndAudit() throws {
        let dir = tmpHome.appendingPathComponent("imgs2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.png"))

        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: [
            "name": "mscope",
            "directories": [dir.path] as [Any?],
            "extensions": ["png"] as [Any?],
        ])
        _ = try tools.call(name: "evaluate_scope", arguments: ["name": "mscope"])
        try Data("x".utf8).write(to: dir.appendingPathComponent("b.png"))
        let result = try tools.call(name: "evaluate_scope", arguments: ["name": "mscope"])
        let text = result.content.first?.text ?? ""
        XCTAssertTrue(text.contains("b.png"))
        XCTAssertTrue(text.contains("\"added\""))

        let audit = try tools.call(name: "get_audit_log", arguments: ["name": "mscope"])
        let auditText = audit.content.first?.text ?? ""
        XCTAssertTrue(auditText.contains("\"entries\""))
        XCTAssertTrue(auditText.contains("\"fileCount\""))

        let diff = try tools.call(name: "get_last_diff", arguments: ["name": "mscope"])
        let diffText = diff.content.first?.text ?? ""
        XCTAssertTrue(diffText.contains("\"currentCount\""))
    }

    func testMCPExportImportRoundTrip() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_rule_set", arguments: [
            "name": "exp_rs", "extensions": ["png"] as [Any?],
        ])
        _ = try tools.call(name: "create_scope", arguments: ["name": "exp_scope"])
        _ = try tools.call(name: "attach_rule_set", arguments: [
            "scope": "exp_scope", "rule_set": "exp_rs",
        ])

        let exported = try tools.call(name: "export_scope", arguments: ["name": "exp_scope"])
        let bundleJSON = exported.content.first?.text ?? ""
        XCTAssertTrue(bundleJSON.contains("exp_scope"))
        XCTAssertTrue(bundleJSON.contains("exp_rs"))

        // Wipe and re-import.
        _ = try tools.call(name: "delete_scope", arguments: ["name": "exp_scope"])
        _ = try tools.call(name: "delete_rule_set", arguments: ["name": "exp_rs"])
        XCTAssertFalse(LocalStorage.shared.scopeExists("exp_scope"))

        let imported = try tools.call(name: "import_scope", arguments: [
            "bundle_json": bundleJSON,
        ])
        XCTAssertFalse(imported.isError ?? false)
        XCTAssertTrue(LocalStorage.shared.scopeExists("exp_scope"))
        XCTAssertTrue(RuleSetStorage.shared.ruleSetExists("exp_rs"))
    }

    func testMCPSetInheritance() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "parent"])
        _ = try tools.call(name: "create_scope", arguments: ["name": "child"])
        _ = try tools.call(name: "set_inheritance", arguments: [
            "name": "child",
            "inherits_from": ["parent"] as [Any?],
        ])
        let scope = try LocalStorage.shared.loadScope("child")
        XCTAssertEqual(scope.inheritsFrom, ["parent"])
    }

    func testDeleteScopeAlsoClearsAuditLog() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "create_scope", arguments: ["name": "todel"])
        try ScopeAuditLog.shared.append(
            ScopeAuditEntry(timestamp: Date(), fileCount: 0),
            scopeName: "todel"
        )
        XCTAssertEqual(try ScopeAuditLog.shared.tail(scopeName: "todel").count, 1)
        _ = try tools.call(name: "delete_scope", arguments: ["name": "todel"])
        XCTAssertEqual(try ScopeAuditLog.shared.tail(scopeName: "todel").count, 0)
    }
}
