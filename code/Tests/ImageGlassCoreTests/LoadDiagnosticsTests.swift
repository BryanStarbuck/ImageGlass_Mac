import XCTest
@testable import ImageGlassCore

/// Coverage for `LoadDiagnostics` and `GitLFSPointer`.
///
/// These tests exercise the failure-classifier that fronts every viewer
/// surface (image, SVG, video, thumbnail). The contract: every failure
/// the user sees on the canvas error card comes from this module, so a
/// regression here silently degrades every load path.
final class LoadDiagnosticsTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("loaddx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - GitLFSPointer

    func testCanonicalLFSPointerDetected() throws {
        let url = try write("logo.png", contents: """
            version https://git-lfs.github.com/spec/v1
            oid sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
            size 12345

            """)
        XCTAssertTrue(GitLFSPointer.isPointer(at: url))
        let dx = LoadDiagnostics.diagnose(url: url)
        guard case .gitLFSPointer = dx else {
            return XCTFail("expected .gitLFSPointer, got \(dx)")
        }
        XCTAssertTrue(dx.userMessage.contains("git lfs pull"))
    }

    func testLFSPointerWithBOM_stillDetected() throws {
        // Some tooling prepends a UTF-8 BOM; the pointer payload below it
        // is still valid LFS content.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append("version https://git-lfs.github.com/spec/v1\n".data(using: .utf8)!)
        let url = sandbox.appendingPathComponent("bom.jpg")
        try data.write(to: url)
        XCTAssertTrue(GitLFSPointer.isPointer(at: url))
    }

    func testNonLFSTextFile_notDetected() throws {
        let url = try write("notes.txt", contents: "hello world\n")
        XCTAssertFalse(GitLFSPointer.isPointer(at: url))
    }

    func testEmptyFile_notDetectedAsLFS_butReportedAsEmpty() throws {
        let url = try write("empty.png", contents: "")
        XCTAssertFalse(GitLFSPointer.isPointer(at: url))
        XCTAssertEqual(LoadDiagnostics.diagnose(url: url), .emptyFile)
    }

    func testRepoRootResolvesToNearestGitDir() throws {
        // sandbox/
        //   repo/.git
        //   repo/sub/img.png   <- pointer
        let repo = sandbox.appendingPathComponent("repo")
        let sub  = repo.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        let img = sub.appendingPathComponent("img.png")
        try "version https://git-lfs.github.com/spec/v1\n"
            .write(to: img, atomically: true, encoding: .utf8)

        let root = try XCTUnwrap(GitLFSPointer.repoRoot(for: img))
        XCTAssertEqual(root.standardizedFileURL.path,
                       repo.standardizedFileURL.path)

        let dx = LoadDiagnostics.diagnose(url: img)
        guard case .gitLFSPointer(let repoRoot) = dx else {
            return XCTFail("expected .gitLFSPointer, got \(dx)")
        }
        let unwrapped = try XCTUnwrap(repoRoot)
        // Message should name the repo so the user knows where to run
        // `git lfs pull` — vague messages were the original complaint.
        XCTAssertTrue(dx.userMessage.contains(unwrapped),
                      "userMessage should mention repo: \(dx.userMessage)")
    }

    func testRepoRoot_acceptsGitFile_forWorktreesAndSubmodules() throws {
        // `git worktree` and submodules use a `.git` *file* (not a dir).
        let repo = sandbox.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "gitdir: /elsewhere/.git/worktrees/foo\n"
            .write(to: repo.appendingPathComponent(".git"),
                   atomically: true, encoding: .utf8)
        let img = repo.appendingPathComponent("img.png")
        try "version https://git-lfs.github.com/spec/v1\n"
            .write(to: img, atomically: true, encoding: .utf8)
        let root = try XCTUnwrap(GitLFSPointer.repoRoot(for: img))
        XCTAssertEqual(root.standardizedFileURL.path,
                       repo.standardizedFileURL.path)
    }

    // MARK: - LoadDiagnostics general

    func testMissingFile_reportsMissing() {
        let url = sandbox.appendingPathComponent("does-not-exist.png")
        XCTAssertEqual(LoadDiagnostics.diagnose(url: url), .missing)
    }

    func testBrokenSymlink_reportsBrokenSymlink() throws {
        let link = sandbox.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "/nowhere/this/does/not/exist.png")
        guard case .brokenSymlink = LoadDiagnostics.diagnose(url: link) else {
            return XCTFail("expected .brokenSymlink")
        }
    }

    func testValidFile_reportsOk() throws {
        // A 1-byte file is enough to satisfy the cheap checks; we are
        // testing the classifier, not the decoder.
        let url = try write("ok.png", contents: "x")
        XCTAssertEqual(LoadDiagnostics.diagnose(url: url), .ok)
    }

    func testProviderHintRecognizesCloudStorageRoots() {
        let home = NSHomeDirectory()
        let dropbox = URL(fileURLWithPath:
            "\(home)/Library/CloudStorage/Dropbox/Photos/a.png")
        XCTAssertEqual(LoadDiagnostics.providerHint(for: dropbox), "Dropbox")

        let gdrive = URL(fileURLWithPath:
            "\(home)/Library/CloudStorage/GoogleDrive-me@x.com/My Drive/a.png")
        XCTAssertEqual(LoadDiagnostics.providerHint(for: gdrive), "Google Drive")

        let local = URL(fileURLWithPath: "\(home)/Pictures/a.png")
        XCTAssertNil(LoadDiagnostics.providerHint(for: local))
    }

    func testDiagnoseAfterDecodeFailure_returnsGenericForLocalFile() throws {
        let url = try write("looks-fine.png", contents: "not really png bytes")
        let dx = LoadDiagnostics.diagnoseAfterDecodeFailure(url: url)
        guard case .generic = dx else {
            return XCTFail("expected .generic for a local non-image, got \(dx)")
        }
    }

    // MARK: - FrameSource.failureReason integration

    func testFailureReason_namesLFSWhenAppropriate() throws {
        let url = try write("bad.png", contents:
            "version https://git-lfs.github.com/spec/v1\n")
        let reason = FrameSource.failureReason(forPath: url.path)
        XCTAssertTrue(reason.contains("Git LFS"),
                      "expected LFS message, got: \(reason)")
        XCTAssertTrue(reason.contains("git lfs pull"))
    }

    // MARK: - Helpers

    private func write(_ name: String, contents: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
