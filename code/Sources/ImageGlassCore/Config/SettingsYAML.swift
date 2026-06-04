import Foundation

/// Emits the `Settings` struct (or any `Encodable` value that round-trips
/// through `JSONEncoder`) as a YAML string. The output is what we drop
/// into `~/Library/Application Support/ImageGlass_Mac/settings.yaml`
/// as the seeded initial configuration for fresh installs.
///
/// We bridge through `JSONEncoder` rather than hand-mapping every
/// section because `Settings` has ~25 sections and the JSON tree is
/// the existing single source of truth — anything `SettingsStore` can
/// persist as JSON can be projected to YAML by walking the same tree.
public enum SettingsYAML {

    /// Banner written above the YAML body so a user opening the file
    /// in a plain text editor understands its provenance.
    public static let header: String = """
    # ImageGlass_Mac — initial settings (seeded on first launch).
    # Edit freely. The runtime persists changes through settings.json;
    # this YAML file is the human-readable starting point.
    """

    public enum EncodeError: Error, CustomStringConvertible {
        case jsonEncodingFailed(Error)
        case unsupportedValue(String)
        public var description: String {
            switch self {
            case .jsonEncodingFailed(let e): return "settings.yaml JSON bridge failed: \(e)"
            case .unsupportedValue(let s):   return "settings.yaml unsupported value: \(s)"
            }
        }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try enc.encode(value)
        } catch {
            throw EncodeError.jsonEncodingFailed(error)
        }
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var out = header + "\n"
        try emit(any, indent: 0, into: &out)
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - Emitter

    private static func emit(_ node: Any, indent: Int, into out: inout String) throws {
        if let dict = node as? [String: Any] {
            try emitMapping(dict, indent: indent, into: &out)
            return
        }
        if let arr = node as? [Any] {
            try emitSequence(arr, indent: indent, into: &out)
            return
        }
        out += scalar(node) + "\n"
    }

    private static func emitMapping(_ dict: [String: Any], indent: Int, into out: inout String) throws {
        let pad = String(repeating: " ", count: indent)
        if dict.isEmpty {
            out += pad + "{}\n"
            return
        }
        for key in dict.keys.sorted() {
            let value = dict[key]!
            let keyText = pad + quoteKeyIfNeeded(key) + ":"
            if isContainer(value), !isEmptyContainer(value) {
                out += keyText + "\n"
                try emit(value, indent: indent + 2, into: &out)
            } else if isEmptyContainer(value) {
                out += keyText + " " + emptyContainerLiteral(value) + "\n"
            } else if value is NSNull {
                out += keyText + " null\n"
            } else {
                out += keyText + " " + scalar(value) + "\n"
            }
        }
    }

    private static func emitSequence(_ arr: [Any], indent: Int, into out: inout String) throws {
        let pad = String(repeating: " ", count: indent)
        if arr.isEmpty {
            out += pad + "[]\n"
            return
        }
        // Use inline flow form for short arrays of scalars (matches the
        // panels.yaml / directories.yaml convention for things like sizes).
        if arr.allSatisfy({ !isContainer($0) }), arr.count <= 8, !anyContainsNewline(arr) {
            let parts = arr.map { scalar($0) }
            out += pad + "[" + parts.joined(separator: ", ") + "]\n"
            return
        }
        for item in arr {
            if let dict = item as? [String: Any] {
                if dict.isEmpty {
                    out += pad + "- {}\n"
                    continue
                }
                let keys = dict.keys.sorted()
                let firstKey = keys.first!
                let firstValue = dict[firstKey]!
                if isContainer(firstValue), !isEmptyContainer(firstValue) {
                    out += pad + "- " + quoteKeyIfNeeded(firstKey) + ":\n"
                    try emit(firstValue, indent: indent + 4, into: &out)
                } else if isEmptyContainer(firstValue) {
                    out += pad + "- " + quoteKeyIfNeeded(firstKey) + ": " + emptyContainerLiteral(firstValue) + "\n"
                } else if firstValue is NSNull {
                    out += pad + "- " + quoteKeyIfNeeded(firstKey) + ": null\n"
                } else {
                    out += pad + "- " + quoteKeyIfNeeded(firstKey) + ": " + scalar(firstValue) + "\n"
                }
                for key in keys.dropFirst() {
                    let value = dict[key]!
                    let keyText = pad + "  " + quoteKeyIfNeeded(key) + ":"
                    if isContainer(value), !isEmptyContainer(value) {
                        out += keyText + "\n"
                        try emit(value, indent: indent + 4, into: &out)
                    } else if isEmptyContainer(value) {
                        out += keyText + " " + emptyContainerLiteral(value) + "\n"
                    } else if value is NSNull {
                        out += keyText + " null\n"
                    } else {
                        out += keyText + " " + scalar(value) + "\n"
                    }
                }
            } else if let nested = item as? [Any] {
                out += pad + "-\n"
                try emit(nested, indent: indent + 2, into: &out)
            } else if item is NSNull {
                out += pad + "- null\n"
            } else {
                out += pad + "- " + scalar(item) + "\n"
            }
        }
    }

    // MARK: - Scalar formatting

    private static func scalar(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let n = value as? NSNumber {
            // Order matters: a CFBoolean is also castable to NSNumber AND
            // to Bool. We disambiguate by CoreFoundation type id, because
            // `value as? Bool` succeeds for numeric 0/1 too — which would
            // serialise `r: 0` as `r: false`. (Real bug; caught in
            // _SeedPreviewSnapshot during development.)
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String { return quoteStringIfNeeded(s) }
        return quoteStringIfNeeded(String(describing: value))
    }

    private static func quoteStringIfNeeded(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        // YAML scalars that look like booleans, nulls, or numbers must
        // be quoted to disambiguate them from those types.
        let reserved: Set<String> = [
            "true", "false", "null", "yes", "no", "on", "off",
            "True", "False", "Null", "Yes", "No", "On", "Off",
            "TRUE", "FALSE", "NULL", "YES", "NO", "ON", "OFF", "~"
        ]
        if reserved.contains(s) { return "\"\(s)\"" }
        if Double(s) != nil { return "\"\(s)\"" }
        if Int(s) != nil { return "\"\(s)\"" }

        let needs = s.contains(":") || s.contains("#") || s.contains("\n")
            || s.contains("\"") || s.contains("\\")
            || s.hasPrefix(" ") || s.hasSuffix(" ")
            || s.hasPrefix("-") || s.hasPrefix("?")
            || s.hasPrefix("[") || s.hasPrefix("{")
            || s.hasPrefix("&") || s.hasPrefix("*")
            || s.hasPrefix("!") || s.hasPrefix("|")
            || s.hasPrefix(">") || s.hasPrefix("'")
            || s.hasPrefix("%") || s.hasPrefix("@") || s.hasPrefix("`")
            || s.hasPrefix(",")
        if !needs { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func quoteKeyIfNeeded(_ s: String) -> String {
        // Keys are simpler than scalars — JSON keys are always strings
        // and our schema uses snake_case identifiers, so the bare form
        // is almost always fine. Quote only when ambiguity would arise.
        if s.isEmpty { return "\"\"" }
        if s.contains(":") || s.contains("#") || s.contains(" ")
            || s.hasPrefix("-") || s.hasPrefix("?") || s.hasPrefix("[")
            || s.hasPrefix("{") || s.hasPrefix(",") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return s
    }

    // MARK: - Container helpers

    private static func isContainer(_ value: Any) -> Bool {
        value is [String: Any] || value is [Any]
    }

    private static func isEmptyContainer(_ value: Any) -> Bool {
        if let d = value as? [String: Any] { return d.isEmpty }
        if let a = value as? [Any] { return a.isEmpty }
        return false
    }

    private static func emptyContainerLiteral(_ value: Any) -> String {
        if value is [String: Any] { return "{}" }
        return "[]"
    }

    private static func anyContainsNewline(_ arr: [Any]) -> Bool {
        arr.contains { v in
            if let s = v as? String { return s.contains("\n") }
            return false
        }
    }
}
