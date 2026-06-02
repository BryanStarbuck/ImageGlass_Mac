import XCTest
@testable import ImageGlassCore

/// Wire-level tests for the MCP server. We drive `handleLineForTests`
/// directly with raw JSON bytes and read back the bytes written to a temp
/// file to verify exact JSON-RPC envelopes.
///
/// We use a real file (not a Pipe) so that "notification → no response"
/// cases can be asserted without `availableData` blocking on an open pipe.
///
/// Covers:
/// * spec §13.1 initialize / tools/list handshake
/// * spec §9 error code mapping
/// * spec §5 notifications produce no response
/// * MCP ping returns `{}`
final class MCPServerTests: XCTestCase {

    private var tmpHome: URL!
    private var originalHome: String?
    private var outURL: URL!
    private var outHandle: FileHandle!
    private var server: MCPServer!

    override func setUpWithError() throws {
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-mcp-srv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tmpHome.path, 1)

        outURL = tmpHome.appendingPathComponent("mcp-out.log")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        outHandle = try FileHandle(forWritingTo: outURL)
        // Input handle is unused — we drive `handleLineForTests` directly.
        let inPipe = Pipe()
        server = MCPServer(
            input: inPipe.fileHandleForReading,
            output: outHandle
        )
    }

    override func tearDownWithError() throws {
        try? outHandle.close()
        try? FileManager.default.removeItem(at: tmpHome)
        if let h = originalHome { setenv("HOME", h, 1) }
    }

    // MARK: - Helpers

    /// Drive one line. Returns the entire byte stream produced by the server
    /// since the start of the test, split on '\n'. Each non-empty frame is a
    /// JSON object.
    @discardableResult
    private func send(_ json: String) throws -> [[String: Any]] {
        server.handleLineForTests(Data(json.utf8))
        try outHandle.synchronize()
        let data = try Data(contentsOf: outURL)
        var frames: [[String: Any]] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let obj = try JSONSerialization.jsonObject(with: Data(line))
            if let dict = obj as? [String: Any] { frames.append(dict) }
        }
        return frames
    }

    private func clearOutput() throws {
        try outHandle.close()
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        outHandle = try FileHandle(forWritingTo: outURL)
        // Rebind into the server. MCPServer holds `output` as an immutable
        // FileHandle — rebuild the server with the new handle.
        let inPipe = Pipe()
        server = MCPServer(
            input: inPipe.fileHandleForReading,
            output: outHandle
        )
    }

    // MARK: - Lifecycle

    func testInitializeReturnsServerInfoAndCapabilities() throws {
        let frames = try send("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}
        """)
        let response = try XCTUnwrap(frames.last)
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 1)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "imageglass-mcp")
        let caps = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(caps["tools"])
    }

    func testInitializeWithoutProtocolVersionAdvertisesOurs() throws {
        let frames = try send("""
        {"jsonrpc":"2.0","id":2,"method":"initialize"}
        """)
        let result = try XCTUnwrap(frames.last?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPServer.supportedProtocolVersion)
    }

    func testInitializedNotificationProducesNoResponse() throws {
        // Per JSON-RPC, no id ⇒ notification ⇒ no response.
        let frames = try send("""
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        """)
        XCTAssertEqual(frames.count, 0, "notifications must not produce a response")
    }

    // MARK: - tools/list

    func testToolsListIncludesAllSpecTools() throws {
        let frames = try send("""
        {"jsonrpc":"2.0","id":3,"method":"tools/list"}
        """)
        let result = try XCTUnwrap(frames.last?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        // Spec §6: the v1 tool surface.
        XCTAssertEqual(names, Set([
            "list_scopes",
            "get_scope",
            "create_scope",
            "set_directories",
            "set_include_criteria",
            "set_exclude_criteria",
            "evaluate_scope",
            "delete_scope",
        ]))
        // Every tool must carry a JSON Schema for inputs.
        for tool in tools {
            XCTAssertNotNil(tool["inputSchema"], "tool \(String(describing: tool["name"])) is missing inputSchema")
            XCTAssertNotNil(tool["description"], "tool \(String(describing: tool["name"])) is missing description")
        }
    }

    // MARK: - ping

    func testPingReturnsEmptyResult() throws {
        let frames = try send("""
        {"jsonrpc":"2.0","id":4,"method":"ping"}
        """)
        let response = try XCTUnwrap(frames.last)
        XCTAssertEqual(response["id"] as? Int, 4)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Error code mapping (spec §9)

    func testParseErrorReturnsM32700() throws {
        let frames = try send("not valid json")
        let err = try XCTUnwrap(frames.last?["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, -32700)
    }

    func testMethodNotFoundReturnsM32601() throws {
        let frames = try send("""
        {"jsonrpc":"2.0","id":7,"method":"does/not/exist"}
        """)
        let err = try XCTUnwrap(frames.last?["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, -32601)
    }

    func testMethodNotFoundForNotificationProducesNoResponse() throws {
        // Notification with unknown method must be silently ignored.
        let frames = try send("""
        {"jsonrpc":"2.0","method":"does/not/exist"}
        """)
        XCTAssertEqual(frames.count, 0)
    }

    func testInvalidParamsOnToolsCallReturnsM32602() throws {
        // Malformed tools/call envelope (missing name) → transport-level invalid params.
        let frames = try send("""
        {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{}}
        """)
        let err = try XCTUnwrap(frames.last?["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, -32602)
    }

    func testInvalidJsonRpcVersionReturnsM32600() throws {
        let frames = try send("""
        {"jsonrpc":"1.0","id":9,"method":"tools/list"}
        """)
        let err = try XCTUnwrap(frames.last?["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, -32600)
    }

    // MARK: - Tool-side validation produces isError result, not protocol error (§9)

    func testUnknownScopeIsToolErrorNotProtocolError() throws {
        let frames = try send("""
        {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_scope","arguments":{"name":"nope"}}}
        """)
        let response = try XCTUnwrap(frames.last)
        // Spec §9: tool errors are RESULTS with isError:true, NOT JSON-RPC errors.
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testUnknownToolIsToolErrorNotProtocolError() throws {
        let frames = try send("""
        {"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"made_up_tool"}}
        """)
        let response = try XCTUnwrap(frames.last)
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }
}
