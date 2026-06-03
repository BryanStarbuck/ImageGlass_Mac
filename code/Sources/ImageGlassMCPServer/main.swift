import Foundation
import ImageGlassCore

// Standalone MCP server — talks JSON-RPC over stdio.
// Launch with:  swift run imageglass-mcp
// or after build: ./.build/debug/imageglass-mcp
//
// Spec §5: transport is stdio. Diagnostics go to stderr only.

do {
    try AppPaths.ensureDirectories()
    try AppPaths.ensureMacDirectories()
    _ = try DirectoriesStore.shared.ensureExists()
    _ = try LocalStorage.shared.bootstrapIfNeeded()
} catch {
    ErrorLog.log("imageglass-mcp bootstrap failed",
                 error: error,
                 class: "ImageGlassMCPServer")
    FileHandle.standardError.write(Data("imageglass-mcp bootstrap warning: \(error)\n".utf8))
}

let server = MCPServer()
server.run()
