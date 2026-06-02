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

## Upstream

Based on [d2phap/ImageGlass](https://github.com/d2phap/ImageGlass), licensed under GPL v3.
