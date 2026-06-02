import XCTest
@testable import ImageGlassCore

final class ExternalToolsTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?

    /// Rebind HOME so on-disk reads/writes land in a tempdir, not the real
    /// `~/Library/Application Support/ImageGlass`.
    override func setUpWithError() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        tmpHome = home
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
        if let original = originalHome {
            setenv("HOME", original, 1)
        }
    }

    // MARK: - Placeholder substitution

    func testFilePlaceholderSubstitution() {
        let argv = ExternalToolLauncher.buildArguments(
            template: "--open <file>",
            filePath: "/Users/me/Pictures/sunset.jpg"
        )
        XCTAssertEqual(argv, ["--open", "/Users/me/Pictures/sunset.jpg"])
    }

    func testPlaceholderInsideQuotedToken() {
        let argv = ExternalToolLauncher.buildArguments(
            template: "--label \"image: <file>\"",
            filePath: "/tmp/a b.jpg"
        )
        XCTAssertEqual(argv, ["--label", "image: /tmp/a b.jpg"])
    }

    func testPlaceholderEmptyWhenNoFile() {
        let argv = ExternalToolLauncher.buildArguments(
            template: "--open <file>",
            filePath: nil
        )
        XCTAssertEqual(argv, ["--open", ""])
    }

    func testNoPlaceholderLeavesArgsUntouched() {
        let argv = ExternalToolLauncher.buildArguments(
            template: "--version",
            filePath: "/whatever.png"
        )
        XCTAssertEqual(argv, ["--version"])
    }

    func testMultiplePlaceholdersInOneArg() {
        let argv = ExternalToolLauncher.buildArguments(
            template: "<file>:<file>",
            filePath: "/a.png"
        )
        XCTAssertEqual(argv, ["/a.png:/a.png"])
    }

    // MARK: - Tokenizer

    func testTokenizerHandlesSingleQuotes() {
        XCTAssertEqual(
            ExternalToolLauncher.tokenize("--name 'hello world'"),
            ["--name", "hello world"]
        )
    }

    func testTokenizerHandlesEscapedSpaces() {
        XCTAssertEqual(
            ExternalToolLauncher.tokenize(#"--path a\ b"#),
            ["--path", "a b"]
        )
    }

    func testTokenizerProducesEmptyTokenForEmptyQuotes() {
        XCTAssertEqual(
            ExternalToolLauncher.tokenize(#"--x "" --y"#),
            ["--x", "", "--y"]
        )
    }

    // MARK: - Persistence round-trip

    func testPersistenceRoundTrip() throws {
        let storage = ExternalToolStorage()
        let tool = ExternalTool(
            id: "my-editor",
            displayName: "My Editor",
            executablePath: "/Applications/MyEditor.app/Contents/MacOS/myeditor",
            arguments: "--open <file>",
            hotkey: "cmd+shift+e",
            integration: true
        )
        try storage.saveTool(tool)

        // On-disk file exists, has plain-text JSON content.
        let url = storage.toolURL(for: "my-editor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let raw = try String(contentsOf: url)
        XCTAssertTrue(raw.contains("\"executablePath\""))
        XCTAssertTrue(raw.contains("my-editor"))

        let loaded = try storage.loadTool("my-editor")
        XCTAssertEqual(loaded, tool)

        let listed = try storage.listToolIds()
        XCTAssertEqual(listed, ["my-editor"])

        try storage.deleteTool("my-editor")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testInvalidIdsRejected() {
        XCTAssertThrowsError(try ExternalToolId.validate(""))
        XCTAssertThrowsError(try ExternalToolId.validate("a/b"))
        XCTAssertThrowsError(try ExternalToolId.validate(".hidden"))
        XCTAssertNoThrow(try ExternalToolId.validate("ok-tool"))
        XCTAssertNoThrow(try ExternalToolId.validate("ExifGlass"))
    }

    func testDeleteUnknownToolThrows() {
        let storage = ExternalToolStorage()
        XCTAssertThrowsError(try storage.deleteTool("does-not-exist"))
    }

    // MARK: - Launcher assembly + missing executable

    func testLaunchMissingExecutableThrows() {
        let tool = ExternalTool(
            id: "ghost",
            executablePath: "/no/such/binary",
            arguments: "<file>"
        )
        XCTAssertThrowsError(
            try ExternalToolLauncher().launch(tool, filePath: "/tmp/x.png")
        ) { err in
            if case ExternalToolError.executableMissing = err {} else {
                XCTFail("expected executableMissing, got \(err)")
            }
        }
    }

    func testLauncherResolvesTilde() {
        let tool = ExternalTool(id: "x", executablePath: "~/bin/foo")
        let resolved = ExternalToolLauncher.resolvedExecutable(for: tool)
        XCTAssertFalse(resolved.hasPrefix("~"))
    }

    func testLaunchActuallyRunsTrueBinary() throws {
        // `/usr/bin/true` exists on macOS and exits 0.
        let tool = ExternalTool(
            id: "trueprog",
            executablePath: "/usr/bin/true",
            arguments: ""
        )
        let proc = try ExternalToolLauncher().launch(tool, filePath: nil)
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }

    // MARK: - MCP integration

    func testMCPRegisterListUnregister() throws {
        let tools = MCPTools()

        // register
        let regResult = try tools.call(name: "register_external_tool", arguments: [
            "id": "ed",
            "display_name": "Ed",
            "executable_path": "/usr/bin/true",
            "arguments": "--open <file>",
            "integration": false,
        ])
        XCTAssertFalse(regResult.isError ?? false)

        // list
        let listResult = try tools.call(name: "list_external_tools", arguments: [:])
        XCTAssertTrue(listResult.content.first?.text.contains("\"ed\"") ?? false)

        // dry-run fire — should not actually spawn (and avoids platform flakiness)
        let dry = try tools.call(name: "fire_external_tool", arguments: [
            "id": "ed",
            "file": "/tmp/picture.png",
            "dry_run": true,
        ])
        XCTAssertFalse(dry.isError ?? false)
        let dryText = dry.content.first?.text ?? ""
        // JSONSerialization escapes forward slashes — accept either form.
        XCTAssertTrue(
            dryText.contains("/tmp/picture.png")
            || dryText.contains(#"\/tmp\/picture.png"#),
            "expected path in dryText: \(dryText)"
        )
        XCTAssertTrue(dryText.contains("\"dryRun\""))

        // duplicate register rejected
        let dup = try tools.call(name: "register_external_tool", arguments: [
            "id": "ed",
            "executable_path": "/usr/bin/true",
        ])
        XCTAssertTrue(dup.isError ?? false)

        // unregister
        let del = try tools.call(name: "unregister_external_tool", arguments: ["id": "ed"])
        XCTAssertFalse(del.isError ?? false)

        XCTAssertFalse(ExternalToolStorage.shared.toolExists("ed"))
    }

    func testMCPUpdatePartialFields() throws {
        let tools = MCPTools()
        _ = try tools.call(name: "register_external_tool", arguments: [
            "id": "ed",
            "executable_path": "/usr/bin/true",
            "arguments": "--old",
        ])
        _ = try tools.call(name: "update_external_tool", arguments: [
            "id": "ed",
            "arguments": "--new <file>",
            "hotkey": "cmd+e",
        ])
        let reloaded = try ExternalToolStorage.shared.loadTool("ed")
        XCTAssertEqual(reloaded.arguments, "--new <file>")
        XCTAssertEqual(reloaded.hotkey, "cmd+e")
        XCTAssertEqual(reloaded.executablePath, "/usr/bin/true")
    }

    func testMCPFireUnknownToolReturnsError() {
        let tools = MCPTools()
        XCTAssertThrowsError(
            try tools.call(name: "fire_external_tool", arguments: ["id": "ghost"])
        )
    }
}
