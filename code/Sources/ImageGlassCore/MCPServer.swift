import Foundation

/// MCP server speaking JSON-RPC 2.0 over a line-delimited stdio channel.
/// One message per line. Reads from `input`, writes to `output`.
///
/// Spec §5: transport is stdio in v1; the server reads JSON-RPC frames from
/// stdin and writes responses to stdout. Diagnostics go to stderr only.
/// Spec §13.1: clients must be able to complete the `initialize` and
/// `tools/list` handshake.
public final class MCPServer {

    /// Latest MCP protocol revision we know how to speak. We will echo back
    /// the client's `protocolVersion` if it asks for the same one, otherwise
    /// we report our own and let the client decide whether to continue.
    public static let supportedProtocolVersion = "2024-11-05"

    public let tools: MCPTools

    private let input: FileHandle
    private let output: FileHandle
    private let serverName: String
    private let serverVersion: String

    public init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        tools: MCPTools = MCPTools(),
        serverName: String = "imageglass-mcp",
        serverVersion: String = AppVersion.semverString
    ) {
        self.input = input
        self.output = output
        self.tools = tools
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    public func run() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty {
                // EOF on stdin — peer disconnected (spec §5: clean exit).
                return
            }
            buffer.append(chunk)

            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<newlineIdx)
                buffer.removeSubrange(0...newlineIdx)
                // Trim trailing CR for clients that send CRLF.
                var trimmed = lineData
                if trimmed.last == 0x0D { trimmed.removeLast() }
                guard !trimmed.isEmpty else { continue }
                handleLine(trimmed, encoder: encoder, decoder: decoder)
            }
        }
    }

    /// Visible for tests: process a single JSON-RPC frame and (when not a
    /// notification) emit the response on the output handle.
    public func handleLineForTests(_ data: Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        handleLine(data, encoder: encoder, decoder: decoder)
    }

    private func handleLine(_ data: Data, encoder: JSONEncoder, decoder: JSONDecoder) {
        // Per JSON-RPC 2.0, a notification has no `id`. We need to distinguish
        // "no id at all" from "id present and null" so we don't reply to
        // notifications. Peek at the raw JSON object first.
        let hasId = jsonHasIdField(data)

        let request: MCP.Request
        do {
            request = try decoder.decode(MCP.Request.self, from: data)
        } catch {
            // Spec §9: protocol-level errors use JSON-RPC reserved codes.
            // -32700 Parse error has no id (id unknown), reply with null id.
            write(MCP.Response.failure(
                id: nil,
                code: -32700,
                message: "Parse error: \(error.localizedDescription)"
            ), encoder: encoder)
            return
        }

        // Per JSON-RPC 2.0 §4.1, jsonrpc MUST be exactly "2.0".
        if request.jsonrpc != "2.0" {
            if hasId {
                write(MCP.Response.failure(
                    id: request.id,
                    code: -32600,
                    message: "Invalid Request: jsonrpc must be '2.0'"
                ), encoder: encoder)
            }
            return
        }

        let response: MCP.Response?
        switch request.method {
        case "initialize":
            response = handleInitialize(request)

        case "tools/list":
            let result = MCP.ListToolsResult(tools: tools.descriptors())
            response = .success(id: request.id, result: AnyCodable(asDict(result)))

        case "tools/call":
            response = handleToolCall(request)

        case "ping":
            // MCP ping returns an empty object as result.
            response = .success(id: request.id, result: AnyCodable([:] as [String: Any]))

        case "notifications/initialized":
            // Pure notification. No reply, even if a stray id is present.
            return

        default:
            // Notifications (no id) never get a reply, even for method-not-found.
            if !hasId { return }
            response = .failure(
                id: request.id,
                code: -32601,
                message: "Method not found: \(request.method)"
            )
        }

        if let r = response, hasId {
            write(r, encoder: encoder)
        }
    }

    private func handleInitialize(_ request: MCP.Request) -> MCP.Response {
        // Echo the client's requested protocolVersion if present; otherwise
        // advertise our own. The client decides whether to proceed.
        var protocolVersion = MCPServer.supportedProtocolVersion
        if let params = request.params?.asDict,
           let requested = params["protocolVersion"] as? String,
           !requested.isEmpty {
            protocolVersion = requested
        }
        let result = MCP.InitializeResult(
            protocolVersion: protocolVersion,
            capabilities: .init(tools: .init(listChanged: false)),
            serverInfo: .init(name: serverName, version: serverVersion)
        )
        return .success(id: request.id, result: AnyCodable(asDict(result)))
    }

    private func handleToolCall(_ request: MCP.Request) -> MCP.Response {
        guard let paramsDict = request.params?.asDict,
              let toolName = paramsDict["name"] as? String, !toolName.isEmpty else {
            // Transport-level invalid params per JSON-RPC; this is a malformed
            // tools/call envelope, not a tool-side validation failure.
            return .failure(
                id: request.id,
                code: -32602,
                message: "Invalid params: expected { name: string, arguments?: object }"
            )
        }
        let args: [String: Any?] = (paramsDict["arguments"] as? [String: Any?]) ?? [:]
        do {
            let callResult = try tools.call(name: toolName, arguments: args)
            return .success(id: request.id, result: AnyCodable(asDict(callResult)))
        } catch {
            // Tools.call is defensive — it should not throw — but if it does,
            // surface as an isError tool result per spec §9, not a JSON-RPC
            // error code.
            let errResult = MCP.CallToolResult.text(
                "Error: \(error.localizedDescription)",
                isError: true
            )
            return .success(id: request.id, result: AnyCodable(asDict(errResult)))
        }
    }

    private func write<T: Encodable>(_ value: T, encoder: JSONEncoder) {
        do {
            var data = try encoder.encode(value)
            data.append(0x0A) // newline-delimited framing
            try output.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("MCP write error: \(error)\n".utf8))
        }
    }

    private func asDict<T: Encodable>(_ value: T) -> [String: Any] {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    /// Peek at the raw JSON to decide whether the request has an `id` field
    /// at all (notification vs request). A request with explicit `id: null`
    /// is still a request per the protocol; a request without an `id` key is
    /// a notification and MUST NOT receive a response.
    private func jsonHasIdField(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else { return false }
        guard let dict = obj as? [String: Any] else { return false }
        return dict.keys.contains("id")
    }
}
