import Foundation

/// Read/write a single setting by dotted path (e.g. `viewer.zoom_mode`).
/// Backs the MCP `get_setting` / `set_setting` tools (spec §2.5). Implemented
/// via JSON round-tripping so we don't have to maintain a parallel reflection
/// table — the JSON keys ARE the canonical path segments.
public enum SettingsPath {

    public enum PathError: Error, Equatable, Sendable, CustomStringConvertible {
        case notFound(String)
        case typeMismatch(path: String, expected: String, got: String)
        case invalidJSON(String)

        public var description: String {
            switch self {
            case .notFound(let p): return "setting not found: \(p)"
            case .typeMismatch(let p, let e, let g):
                return "type mismatch at \(p): expected \(e), got \(g)"
            case .invalidJSON(let why): return "invalid JSON: \(why)"
            }
        }
    }

    /// Lists every dotted path that exists in `settings` paired with its
    /// JSON value. Mirrors the MCP `list_setting_paths()` tool.
    public static func listPaths(_ settings: Settings) -> [(path: String, value: Any)] {
        let json: [String: Any]
        do {
            json = try encodeToJSONObject(settings)
        } catch {
            ErrorLog.log("encodeToJSONObject failed in listPaths",
                         error: error,
                         class: "SettingsPath")
            json = [:]
        }
        var out: [(String, Any)] = []
        flatten(json, prefix: "", into: &out)
        return out.sorted(by: { $0.0 < $1.0 })
    }

    private static func flatten(_ value: Any, prefix: String, into out: inout [(String, Any)]) {
        if let dict = value as? [String: Any] {
            for (k, v) in dict {
                let next = prefix.isEmpty ? k : "\(prefix).\(k)"
                if v is [String: Any] {
                    flatten(v, prefix: next, into: &out)
                } else {
                    out.append((next, v))
                }
            }
        } else {
            out.append((prefix, value))
        }
    }

    /// Returns the value at `path` as a JSON-serializable Any.
    public static func get(_ path: String, in settings: Settings) throws -> Any {
        let json = try encodeToJSONObject(settings)
        let keys = path.split(separator: ".").map(String.init)
        var node: Any = json
        for (i, key) in keys.enumerated() {
            guard let dict = node as? [String: Any], let next = dict[key] else {
                throw PathError.notFound(keys.prefix(i + 1).joined(separator: "."))
            }
            node = next
        }
        return node
    }

    /// Sets the value at `path` in `settings` (mutates in place) by patching
    /// the JSON tree and re-decoding. Returns the prior value for undo.
    @discardableResult
    public static func set(_ path: String, value: Any, in settings: inout Settings) throws -> Any {
        let previous: Any
        do {
            previous = try get(path, in: settings)
        } catch {
            previous = NSNull()
        }
        var json = try encodeToJSONObject(settings)
        let keys = path.split(separator: ".").map(String.init)
        try patch(&json, keys: keys, with: value)
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        do {
            var updated = try JSONDecoder().decode(Settings.self, from: data)
            SettingsValidation.clamp(&updated)
            settings = updated
        } catch let DecodingError.typeMismatch(_, ctx) {
            let p = ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
            throw PathError.typeMismatch(path: p.isEmpty ? path : p, expected: ctx.debugDescription, got: "\(type(of: value))")
        } catch {
            throw PathError.invalidJSON(String(describing: error))
        }
        return previous
    }

    private static func patch(_ json: inout [String: Any], keys: [String], with value: Any) throws {
        guard let head = keys.first else { return }
        if keys.count == 1 {
            json[head] = value
            return
        }
        var child: [String: Any] = (json[head] as? [String: Any]) ?? [:]
        try patch(&child, keys: Array(keys.dropFirst()), with: value)
        json[head] = child
    }

    private static func encodeToJSONObject(_ settings: Settings) throws -> [String: Any] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(settings)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PathError.invalidJSON("root is not an object")
        }
        return obj
    }
}
