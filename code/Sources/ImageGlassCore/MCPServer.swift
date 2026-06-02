import Foundation

/// MCP server speaking JSON-RPC 2.0 over a line-delimited stdio channel.
/// One message per line. Reads from `input`, writes to `output`.
public final class MCPServer {

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
        serverVersion: String = "0.1.0"
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
                // EOF on stdin — peer disconnected.
                return
            }
            buffer.append(chunk)

            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<newlineIdx)
                buffer.removeSubrange(0...newlineIdx)
                guard !lineData.isEmpty else { continue }
                handleLine(lineData, encoder: encoder, decoder: decoder)
            }
        }
    }

    private func handleLine(_ data: Data, encoder: JSONEncoder, decoder: JSONDecoder) {
        let request: MCP.Request
        do {
            request = try decoder.decode(MCP.Request.self, from: data)
        } catch {
            write(MCP.Response.failure(id: nil, code: -32700, message: "Parse error: \(error.localizedDescription)"), encoder: encoder)
            return
        }

        let response: MCP.Response
        switch request.method {
        case "initialize":
            let result = MCP.InitializeResult(
                protocolVersion: "2024-11-05",
                capabilities: .init(tools: .init(listChanged: false)),
                serverInfo: .init(name: serverName, version: serverVersion)
            )
            response = .success(id: request.id, result: AnyCodable(asDict(result)))

        case "tools/list":
            let result = MCP.ListToolsResult(tools: tools.descriptors())
            response = .success(id: request.id, result: AnyCodable(asDict(result)))

        case "tools/call":
            response = handleToolCall(request)

        case "notifications/initialized", "ping":
            // Notifications don't need a response; ping gets an empty result.
            if request.id != nil {
                response = .success(id: request.id, result: AnyCodable([:] as [String: Any]))
            } else {
                return
            }

        default:
            response = .failure(id: request.id, code: -32601, message: "Method not found: \(request.method)")
        }

        write(response, encoder: encoder)
    }

    private func handleToolCall(_ request: MCP.Request) -> MCP.Response {
        guard let paramsDict = request.params?.asDict,
              let toolName = paramsDict["name"] as? String else {
            return .failure(id: request.id, code: -32602, message: "Invalid params: expected { name, arguments }")
        }
        let args: [String: Any?] = (paramsDict["arguments"] as? [String: Any?]) ?? [:]
        do {
            let callResult = try tools.call(name: toolName, arguments: args)
            return .success(id: request.id, result: AnyCodable(asDict(callResult)))
        } catch {
            let errResult = MCP.CallToolResult.text("Error: \(error)", isError: true)
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
}
