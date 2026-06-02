# ImageGlass Mac (Starbuck Fork)

A native macOS rebuild of [ImageGlass](https://imageglass.org), extended with
the Starbuck fork's five charter features:

1. **MCP server** — Claude Code drives the viewer.
2. **Modular panel column** — first panel is Directory/Filename (list + tree).
3. **Scope controls** — include/exclude rules over directories, globs, extensions.
4. **Local Storage** — plain-text scope files on disk.
5. **MCP-driven editing** of Local Storage — no GUI required to change scopes.

See `../docs/` for the full specification.

## Layout

```
code/
├── Package.swift
├── Sources/
│   ├── ImageGlassCore/      # Library: LocalStorage, Scope, MCP protocol
│   ├── ImageGlass/          # Executable: SwiftUI app
│   └── ImageGlassMCPServer/ # Executable: standalone MCP server (stdio)
└── Tests/
    └── ImageGlassCoreTests/
```

## Build & Run

```sh
# Build everything
swift build

# Run the app
swift run ImageGlass

# Run the MCP server standalone (talks JSON-RPC over stdio)
swift run imageglass-mcp

# Tests
swift test
```

## Local Storage Location

Scope files live as plain JSON in:

```
~/Library/Application Support/ImageGlass/scopes/<scope-name>.json
```

Each file records source directories, include/exclude criteria, the last
evaluation timestamp, and the resolved file list.

## Charter Status API

`ImageGlassCore` exposes a high-level audit of the five fork-charter goals
from `docs/overview.mdx`. Use it from anywhere — app, MCP server, CI, tests:

```swift
import ImageGlassCore

let report = ImageGlassCore.charterStatus()
print(ImageGlassCore.charterSummary())
// e.g. "ImageGlass charter: 5 implemented, 0 partial, 0 missing (of 5)."

for entry in report.goals {
    print("#\(entry.goal.index) \(entry.goal.title) → \(entry.state.rawValue)")
}
```

The same report is reachable over MCP via the `charter_status` tool, so a
Claude Code session can audit the charter without opening the GUI.

This is deliberately a *high-level* check — per-subsystem detail belongs in
the matching spec (`panels.mdx`, `starbuck-fork.mdx`, etc.).

## Status

Early scaffold. Charter features come online in this order:
Local Storage → Scope engine → Panel column → Viewer → MCP server → reactive wiring.
