# ImageGlass_Mac

A **macOS-native image previewing app** — Bryan Starbuck's macOS-focused fork of the [ImageGlass](https://github.com/d2phap/ImageGlass) project.

The goal is a fast, modern, ad-free image viewer that feels like a first-class macOS app — native window chrome, gestures, dark/light system theme, and Apple Silicon performance — while preserving the broad format support and viewing features ImageGlass is known for.

This fork is **not** a cross-platform rebuild. It is a Mac-first product. Upstream Windows-specific code paths (WebView2, File Explorer integration, Microsoft Store packaging, Windows 11 backdrop, etc.) are not the target.

## What's Different in This Fork

On top of the Mac-native viewer baseline, this fork adds:

1. **MCP support** — A Model Context Protocol server so Claude Code (and other MCP clients) can drive and configure ImageGlass from outside the application.

2. **Modular UI panels** — A new column in the UI that hosts modular panels. The initial panel is a **directory / filename panel** listing the images currently in scope, with a toggle into a **file-tree view** of the same files. The architecture is panel-based so additional panels can be added over time.

3. **Scope controls** — Explicit controls for what is included in (and excluded from) the active file list. Scopes can be expressed as directories, directory hierarchies, glob/extension criteria, or named rule sets.

4. **Local Storage** — A local-filesystem-backed configuration store kept as plain text files on disk. Each entry records the last scope evaluation time, the resolved file list, and the source directories or criteria that drove the scope. At runtime, Local Storage holds the scope definitions, walks the matching directories, and the resolved list is what gets shown in the directory/filename panel.

5. **MCP-driven editing of Local Storage** — Because Local Storage is plain text and is fronted by the MCP server, Claude Code can read and modify scope definitions, swap in new directory lists, change inclusion/exclusion criteria, and trigger re-evaluation — without the user editing settings inside the GUI.

## Platform

macOS only. Optimized for Apple Silicon.

## Quick Start

```sh
brew install just              # one-time, if you don't have it
just bootstrap                 # fetches deps, runs first build
just run                       # launch the app
```

`just bootstrap` is the only command a fresh clone needs. It verifies your
host tooling, runs SwiftPM dependency resolution, fetches any native
libraries into `vendor/` (none today — Apple's ImageIO covers the current
format set), and does a debug build.

Run `just` with no arguments to see every recipe. Build settings,
dependency lists, and the vendor-library policy live in `justfile` and
`vendor/CLAUDE.md` so they're discoverable from a checkout alone.

## Repository Layout

```
ImageGlass_Mac/
├── justfile              # task runner — `just` to list recipes
├── .gitignore            # excludes .build, .claude/worktrees, vendor contents
├── code/                 # Swift package (app, MCP server, core lib)
├── docs/                 # MDX specification
└── vendor/               # native dependency staging (contents gitignored)
    ├── README.md
    └── CLAUDE.md         # spec for adding vendored libraries
```

## MCP Server

The fork ships a standalone MCP server, `imageglass-mcp`, that speaks
JSON-RPC 2.0 over line-delimited **stdio** (one message per line; stdout
is the protocol channel, stderr is diagnostics-only). It is the sole
sanctioned automation surface for ImageGlass_Mac — Claude Code and any
other MCP client edit scopes, Local Storage, external-tool registrations,
and the crop pipeline through this server.

### Build and Launch

```sh
just build                                # one-time, or after a pull
just mcp                                  # launch on stdio (foreground)
# equivalent direct invocation:
swift run --package-path code imageglass-mcp
# after a release build:
./code/.build/release/imageglass-mcp
```

The binary reads JSON-RPC frames from stdin and writes responses to
stdout. It exits when stdin closes. There is no network port — clients
spawn it as a child process.

### Register with Claude Code

Add the server to Claude Code's MCP config (`~/.claude/mcp.json` or the
per-project equivalent):

```json
{
  "mcpServers": {
    "imageglass": {
      "command": "/Users/<you>/BGit/tools_various/ImageGlass_Mac/code/.build/release/imageglass-mcp",
      "args": []
    }
  }
}
```

Or register from the CLI:

```sh
claude mcp add imageglass \
  /Users/<you>/BGit/tools_various/ImageGlass_Mac/code/.build/release/imageglass-mcp
```

Confirm with `claude mcp list` — the entry should report **Connected**.
For other MCP clients (Claude Desktop, custom hosts), the same `command`
+ stdio transport applies.

### Handshake

The server implements the standard MCP methods:

* `initialize`
* `notifications/initialized`
* `tools/list`
* `tools/call`
* `ping`

After `initialize`, call `tools/list` to discover the exact JSON schema
of every tool below — argument names, types, and descriptions are
authoritative there, not in this README.

### Tools

Argument names and types are authoritative in `tools/list` — names below
are abbreviated for orientation only.

**Scopes and Local Storage** — the primary surface. Scope definitions
are plain JSON files that the server reads and writes; the viewer picks
up changes on re-evaluation.

* `list_scopes` — enumerate every defined scope.
* `get_scope` — fetch a scope's full definition and last resolved file
  list.
* `create_scope` — define a new scope.
* `set_directories` — replace the source directories that drive a scope.
* `set_include_criteria` — set glob/extension include rules.
* `set_exclude_criteria` — set glob/extension exclude rules.
* `evaluate_scope` — walk the directories now and refresh the resolved
  file list.
* `delete_scope` — remove a scope.
* `export_scope` / `import_scope` — move scope definitions between
  machines as portable JSON.

**Rule sets and inheritance** — reusable include/exclude rule bundles
that can be attached to one or more scopes.

* `list_rule_sets`, `get_rule_set`, `create_rule_set`, `delete_rule_set`
* `attach_rule_set` / `detach_rule_set` — bind a rule set to a scope.
* `set_inheritance` — control how attached rule sets combine.
* `get_effective_rules` — preview the resolved include/exclude after
  inheritance is applied.

**Themes**

* `list_themes`, `get_current_theme`, `set_current_theme`.

**External tools** — third-party apps registered with ImageGlass (see
`docs/build-tools.mdx`). The viewer can fire these against the current
image.

* `list_external_tools`, `register_external_tool`,
  `update_external_tool`, `unregister_external_tool`.
* `fire_external_tool` — launch a registered tool against an image path.

**Crop pipeline** — read or set the crop selection and run the crop.

* `read_image_dimensions`, `get_crop_selection`, `set_crop_selection`,
  `crop_image`.

**Diagnostics**

* `charter_status` — reports fork-charter goal state and tool count.
* `get_audit_log` — recent MCP write operations.
* `get_last_diff` — diff of the last scope/rule-set mutation.

### Local Storage on Disk

Everything the MCP server reads or writes lives under:

```
~/Library/Application Support/ImageGlass/
├── scopes/             # one JSON file per named scope
├── rulesets/           # reusable include/exclude bundles
├── themes/             # installed theme packs
├── tools/              # external-tool registrations
├── runtime/            # transient runtime state
├── audit/              # MCP write audit log
├── languages/          # localization assets
├── current-theme.txt   # active theme name
└── igconfig.json       # app-level settings
```

Every file is plain text (JSON or `.txt`). You can `cat`, `diff`, or
hand-edit them — the GUI and the MCP server share the same files, so a
change made by either is visible to the other on the next evaluation.

### Smoke Test

Confirm the server is live by piping a handshake plus a `list_scopes`
call into it:

```sh
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoketest","version":"0.0.1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_scopes","arguments":{}}}'
} | ./code/.build/release/imageglass-mcp | jq -c '.'
```

A working server prints four lines: the `initialize` result, nothing for
the notification, and the `list_scopes` result. On a fresh install the
list contains the bootstrap scope `crop-live`.

## Upstream

Based on [d2phap/ImageGlass](https://github.com/d2phap/ImageGlass), licensed under GPL v3.
