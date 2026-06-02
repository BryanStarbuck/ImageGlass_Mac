import Foundation

/// Minimal JSON-RPC 2.0 message types used by the MCP server.
/// MCP layers JSON-RPC over stdio; this is the wire format.
public enum MCP {

    public struct Request: Codable, Sendable {
        public let jsonrpc: String
        public let id: AnyCodable?
        public let method: String
        public let params: AnyCodable?
    }

    public struct Response: Codable, Sendable {
        public let jsonrpc: String
        public let id: AnyCodable?
        public let result: AnyCodable?
        public let error: ErrorBody?

        public static func success(id: AnyCodable?, result: AnyCodable) -> Response {
            Response(jsonrpc: "2.0", id: id, result: result, error: nil)
        }

        public static func failure(id: AnyCodable?, code: Int, message: String) -> Response {
            Response(jsonrpc: "2.0", id: id, result: nil, error: .init(code: code, message: message, data: nil))
        }
    }

    public struct ErrorBody: Codable, Sendable {
        public let code: Int
        public let message: String
        public let data: AnyCodable?
    }

    // MCP-specific structures

    public struct ServerInfo: Codable, Sendable {
        public let name: String
        public let version: String
    }

    public struct ToolDescriptor: Codable, Sendable {
        public let name: String
        public let description: String
        public let inputSchema: AnyCodable
    }

    public struct InitializeResult: Codable, Sendable {
        public let protocolVersion: String
        public let capabilities: Capabilities
        public let serverInfo: ServerInfo

        public struct Capabilities: Codable, Sendable {
            public let tools: ToolsCap
            public struct ToolsCap: Codable, Sendable {
                public let listChanged: Bool
            }
        }
    }

    public struct ListToolsResult: Codable, Sendable {
        public let tools: [ToolDescriptor]
    }

    public struct CallToolParams: Codable, Sendable {
        public let name: String
        public let arguments: AnyCodable?
    }

    public struct CallToolResult: Codable, Sendable {
        public let content: [ContentBlock]
        public let isError: Bool?

        public struct ContentBlock: Codable, Sendable {
            public let type: String
            public let text: String
        }

        public static func text(_ s: String, isError: Bool = false) -> CallToolResult {
            CallToolResult(content: [.init(type: "text", text: s)], isError: isError)
        }
    }
}

/// Erased JSON value — needed because JSON-RPC `params`/`result` are untyped.
/// `@unchecked Sendable` because `Any?` is intrinsically untyped; values held
/// here are JSON-shaped (Bool/Int/Double/String/Array/Dict) and treated as
/// immutable after construction.
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any?

    public init(_ value: Any?) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = nil; return }
        if let b = try? c.decode(Bool.self) { self.value = b; return }
        if let i = try? c.decode(Int.self) { self.value = i; return }
        if let d = try? c.decode(Double.self) { self.value = d; return }
        if let s = try? c.decode(String.self) { self.value = s; return }
        if let arr = try? c.decode([AnyCodable].self) { self.value = arr.map { $0.value }; return }
        if let dict = try? c.decode([String: AnyCodable].self) {
            var out: [String: Any?] = [:]
            for (k, v) in dict { out[k] = v.value }
            self.value = out
            return
        }
        self.value = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        guard let v = value else { try c.encodeNil(); return }
        switch v {
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let i as Int64: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [Any?]: try c.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any?]:
            var out: [String: AnyCodable] = [:]
            for (k, val) in dict { out[k] = AnyCodable(val) }
            try c.encode(out)
        case let dict as [String: Any]:
            var out: [String: AnyCodable] = [:]
            for (k, val) in dict { out[k] = AnyCodable(val) }
            try c.encode(out)
        case let enc as Encodable:
            try enc.encode(to: encoder)
        default:
            try c.encodeNil()
        }
    }

    public var asDict: [String: Any?]? { value as? [String: Any?] }
    public var asString: String? { value as? String }
    public var asInt: Int? { value as? Int }
    public var asBool: Bool? { value as? Bool }
    public var asArray: [Any?]? { value as? [Any?] }
}
