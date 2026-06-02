import Foundation
import ImageGlassCore

// Standalone MCP server — talks JSON-RPC over stdio.
// Launch with:  swift run imageglass-mcp
// or after build: ./.build/debug/imageglass-mcp

try? AppPaths.ensureDirectories()
try? LocalStorage.shared.bootstrapIfNeeded()

let server = MCPServer()
server.run()
