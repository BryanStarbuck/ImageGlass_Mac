import Foundation
import ImageGlassCore

// Standalone MCP server — talks JSON-RPC over stdio.
// Launch with:  swift run imageglass-mcp
// or after build: ./.build/debug/imageglass-mcp

do {
    try AppPaths.ensureDirectories()
    _ = try LocalStorage.shared.bootstrapIfNeeded()
} catch {
    FileHandle.standardError.write(Data("imageglass-mcp bootstrap warning: \(error)\n".utf8))
}

let server = MCPServer()
server.run()
