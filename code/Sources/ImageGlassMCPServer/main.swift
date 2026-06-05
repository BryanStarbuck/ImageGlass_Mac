import Foundation
import ImageGlassCore

// Standalone MCP server — talks JSON-RPC over stdio.
// Launch with:  swift run imageglass-mcp
// or after build: ./.build/debug/imageglass-mcp
//
// Spec §5: transport is stdio. Diagnostics go to stderr only.

// docs/performance.mdx §5.6 / §10.12 — `MCP.Server.Boot` covers the
// full startup path (ensure dirs, ensure stores, construct server,
// hand off to its event loop). Emitted as both an event (the marker
// that the process has gotten past bootstrap) and an interval (the
// elapsed time the bootstrap consumed).
PerformanceLog.shared.event("MCP.Server.Boot")
let _bootTrace = PerformanceLog.shared.start("MCP.Server.Boot")

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
_bootTrace.finish()
server.run()
