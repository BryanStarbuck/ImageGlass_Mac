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
}
