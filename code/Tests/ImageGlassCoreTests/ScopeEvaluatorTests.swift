import XCTest
@testable import ImageGlassCore

final class ScopeEvaluatorTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func write(_ name: String, in subdir: String = "") -> String {
        let dir = subdir.isEmpty ? tmpDir! : tmpDir.appendingPathComponent(subdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? Data("x".utf8).write(to: url)
        return url.path
    }

    func testIncludesByExtension() {
        _ = write("a.png")
        _ = write("b.jpg")
        _ = write("readme.txt")

        let scope = Scope(
            name: "t",
            include: .init(directories: [tmpDir.path], recursive: false, extensions: ["png", "jpg"]),
            exclude: .init(hiddenFiles: true)
        )
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(Set(files), Set(["a.png", "b.jpg"]))
    }

    func testRecursiveWalk() {
        _ = write("top.png")
        _ = write("nested.png", in: "sub")

        let scope = Scope(
            name: "t",
            include: .init(directories: [tmpDir.path], recursive: true, extensions: ["png"]),
            exclude: .init(hiddenFiles: true)
        )
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(Set(files), Set(["top.png", "nested.png"]))
    }

    func testExcludeGlob() {
        _ = write("good.png")
        _ = write("draft_old.png")

        let scope = Scope(
            name: "t",
            include: .init(directories: [tmpDir.path], recursive: false, extensions: ["png"]),
            exclude: .init(globs: ["*_old*"], hiddenFiles: true)
        )
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(files, ["good.png"])
    }

    func testHiddenFilesExcluded() {
        _ = write(".hidden.png")
        _ = write("visible.png")

        let scope = Scope(
            name: "t",
            include: .init(directories: [tmpDir.path], recursive: false, extensions: ["png"]),
            exclude: .init(hiddenFiles: true)
        )
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(files, ["visible.png"])
    }

    // MARK: - Multi-criteria + new fields (spec §3.1)

    func testMultipleCriteriaUnion() {
        _ = write("a.png", in: "left")
        _ = write("b.png", in: "right")
        let scope = Scope(
            name: "multi",
            criteria: [
                .init(root: tmpDir.appendingPathComponent("left").path,
                      recursive: true, includeExts: ["png"]),
                .init(root: tmpDir.appendingPathComponent("right").path,
                      recursive: true, includeExts: ["png"]),
            ]
        )
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(Set(files), Set(["a.png", "b.png"]))
    }

    func testMaxDepthLimitsRecursion() {
        _ = write("top.png")
        _ = write("d1.png", in: "sub")
        _ = write("d2.png", in: "sub/deeper")

        let scope = Scope(
            name: "depth",
            criteria: [
                .init(root: tmpDir.path,
                      recursive: true,
                      maxDepth: 1,
                      includeExts: ["png"])
            ]
        )
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(Set(files), Set(["top.png", "d1.png"]))
    }

    func testIncludeHiddenPerCriterion() {
        _ = write(".hidden.png")
        _ = write("visible.png")
        let scope = Scope(
            name: "h",
            criteria: [
                .init(root: tmpDir.path,
                      recursive: false,
                      includeExts: ["png"],
                      includeHidden: true)
            ]
        )
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(Set(files), Set([".hidden.png", "visible.png"]))
    }

    func testExcludeGlobsMatchFullPath() {
        _ = write("keep.png", in: "live")
        _ = write("trash.png", in: "_archive")
        let scope = Scope(
            name: "exc",
            criteria: [
                .init(root: tmpDir.path,
                      recursive: true,
                      includeExts: ["png"],
                      excludeGlobs: ["**/_archive/**"])
            ]
        )
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(Set(files), Set(["keep.png"]))
    }

    func testExcludeExts() {
        _ = write("ok.png")
        _ = write("bad.bak")
        let scope = Scope(
            name: "ex",
            criteria: [
                .init(root: tmpDir.path,
                      recursive: false,
                      includeExts: ["png", "bak"],
                      excludeExts: ["bak"])
            ]
        )
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(files, ["ok.png"])
    }

    func testScopeSortByModifiedDesc() throws {
        let p1 = write("a.png")
        let p2 = write("b.png")
        // Make a.png older than b.png explicitly.
        let oldDate = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: p1)

        var scope = Scope(
            name: "sort",
            criteria: [.init(root: tmpDir.path, recursive: false, includeExts: ["png"])]
        )
        scope.sort = .init(by: .modified, direction: .desc)
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(files.first, "b.png")
        XCTAssertEqual(files.last, "a.png")
        _ = p2
    }

    func testScopeFilterTextSubstring() {
        _ = write("sunset.png")
        _ = write("skyline.png")
        var scope = Scope(
            name: "f",
            criteria: [.init(root: tmpDir.path, recursive: false, includeExts: ["png"])]
        )
        scope.filter = .init(text: "sun")
        let files = ScopeEvaluator.resolveFiles(for: scope).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(files, ["sunset.png"])
    }

    func testResolvedFileCarriesMetadata() {
        _ = write("a.png")
        let scope = Scope(
            name: "meta",
            criteria: [.init(root: tmpDir.path, recursive: false, includeExts: ["png"])]
        )
        let entries = ScopeEvaluator.resolveEntries(for: scope)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries[0].size)
        XCTAssertNotNil(entries[0].modified)
    }
}
