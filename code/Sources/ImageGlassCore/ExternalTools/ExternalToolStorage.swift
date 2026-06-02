import Foundation

/// Plain-text on-disk store of external-tool descriptors.
///
/// Format: pretty-printed JSON, one file per tool, in
/// `~/Library/Application Support/ImageGlass/tools/<id>.json`.
///
/// Charter: plain text. JSON is the lingua franca already used by `LocalStorage`
/// for scopes, so reusing it here keeps the on-disk story uniform and lets
/// users hand-edit tool descriptors with any text editor.
public final class ExternalToolStorage {

    public static let shared = ExternalToolStorage()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc

        let dec = JSONDecoder()
        self.decoder = dec
    }

    // MARK: - Discovery

    public func listToolIds() throws -> [String] {
        try AppPaths.ensureDirectories()
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: AppPaths.toolsDir,
            includingPropertiesForKeys: nil
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public func listTools() throws -> [ExternalTool] {
        try listToolIds().compactMap { try? loadTool($0) }
    }

    public func toolURL(for id: String) -> URL {
        AppPaths.toolsDir.appendingPathComponent("\(id).json")
    }

    public func toolExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: toolURL(for: id).path)
    }

    // MARK: - Read / Write

    public func loadTool(_ id: String) throws -> ExternalTool {
        try ExternalToolId.validate(id)
        let url = toolURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExternalToolError.notFound(id)
        }
        let data = try Data(contentsOf: url)
        var tool = try decoder.decode(ExternalTool.self, from: data)
        tool.id = id // filename is authoritative
        return tool
    }

    public func saveTool(_ tool: ExternalTool) throws {
        try ExternalToolId.validate(tool.id)
        try AppPaths.ensureDirectories()
        let url = toolURL(for: tool.id)
        let data = try encoder.encode(tool)
        try data.write(to: url, options: .atomic)
    }

    public func deleteTool(_ id: String) throws {
        try ExternalToolId.validate(id)
        let url = toolURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExternalToolError.notFound(id)
        }
        try FileManager.default.removeItem(at: url)
    }
}
