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

## Upstream

Based on [d2phap/ImageGlass](https://github.com/d2phap/ImageGlass), licensed under GPL v3.
