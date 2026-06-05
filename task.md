# ImageGlass_Mac — Task List

Tasks derived from the 2026-06-04 Zoom meeting with Bryan Starbuck. Owner: Erin
Rai (assigned — has a Mac laptop). Goal: a Mac-native image previewer that
Claude Code drives via MCP, used to tour design images quickly in meetings.

**Status (2026-06-05):** P0 + P1 + P2 done/verified. Claude Design handoff
(File Panel + Canvas) implemented. See `new_docs.md` (architecture) and
`design_prompt.md` (design brief). Tests: 467 run, 12 pre-existing failures in
CharterTests/MCPToolsHardeningTests (ruleset/inheritance — NOT from this work,
reproduce on clean checkout).

## Context — what Bryan needs

- Preview design images on Mac. Preview.app and off-the-shelf tools choke when
  opening ~2000 images (memory blows up).
- Claude Code drives it via MCP: pass subproject paths → filter out junk
  (dark-mode / low-quality) → tour designs fast, click through, give UI feedback
  ("move this, add a radio button") live in meetings.
- Going open-source on Bryan's personal GitHub, outside the Act3 org.

---

## P0 — broken, blocks everything  ✅ DONE

- [x] **File tree renders.** Root cause was deeper than the renderer default:
      the AppKit `NSViewRepresentable` image canvas was overdrawing its bounds
      and painting over the sidebar. Fixes: (a) rewrote the inline panel tree as
      pure SwiftUI (`DesignTreeNode.swift`, no `NSOutlineView`); (b) `.clipped()`
      on the viewer so the canvas can't overdraw the panel; (c) `layoutPriority`
      so the greedy canvas can't squeeze the column to 0; (d) default renderer
      → AppKit for the floating tree. `ContentView.swift`,
      `DirectoryFilenamePanel.swift`, `DesignTreeNode.swift`.
- [x] **Memory choke addressed.** `ThumbnailCache` is bounded: NSCache 256
      entries in memory + 1 GB disk LRU, ImageIO **downscaled** thumbnails (not
      full images), actor (off-main). The redesigned panel uses `LazyVStack` +
      SF Symbol icons (no bulk thumbnail decode); the viewer loads one image at
      a time; the walker only enumerates paths. 2000 images won't choke.
- [x] **`buildTree()` cached.** Was rebuilt every render; now cached +
      invalidated on visible-set change. `FileListViewModel.swift`.

## P1 — core workflow Bryan described  ✅ VERIFIED

- [x] **MCP: add root directories.** `add_directory` tool — verified live over
      stdio (returns `already_exists`, writes `directories.yaml`).
      `DirectoriesMCPTools.swift`.
- [x] **MCP: push filter criteria.** `update_directory_filter` /
      `set_exclude_criteria` — verified live: `_dark_`/`_dn_` substring+negate
      filter applied and persisted (`negate_items:1`). Exclusion semantics in
      `DirectoryTree.RootFilter.evaluate`.
- [x] **Background recursive walk + filter.** `DirectoryTreeWalker` is an actor;
      walks on `Task.detached(.utility)` off the main thread. Verified a demo
      walk: 16 files → 13 after `_dark_`/`_dn_` exclude.
- [x] **`directories.yaml` naming.** On disk at
      `~/Library/Application Support/ImageGlass_Mac/directories.yaml`, plain text,
      human-readable — matches Bryan's mental model.

## P2 — viewer UX for meetings  ✅ VERIFIED

- [x] **Pinch-zoom + pan.** `ImageCanvasView.magnify(with:)` (pinch) +
      `scrollWheel` (pan). Plus a floating glass zoom cluster
      (`ViewerZoomControls.swift`): fit/100/fill/−/%/+/rotate/flip, 6 zoom modes.
- [x] **Fast click-through.** Click filename → `state.selectedFile` → viewer
      loads instantly (verified live). Arrow keys → `selectPrevious`/`selectNext`.
- [x] **Left tree / right preview split.** `ContentView` HStack: design file
      panel (300pt) | divider | image viewer + status bar.

## P3 — setup / handoff

- [x] **Builds on Mac.** `swift build --product ImageGlass` clean (errors: 0).
      `just` not installed locally — used `swift build` directly; `just run`
      works once `brew install just`.
- [x] **End-to-end smoke test.** Demo flow verified: MCP adds root → pushes
      `_dark_` exclude → tree shows 13 filtered files → click loads image in the
      viewer. Screenshots captured during the session.

---

## Notes for next dev

- **AppKit-canvas overdraw gotcha:** any SwiftUI chrome beside the image canvas
  must `.clipped()` the viewer, or the `NSViewRepresentable` paints over it.
- **Pre-existing test failures (12):** CharterTests + MCPToolsHardeningTests
  (ruleSets / inheritance / scope-bundle round-trip). Reproduce on a clean
  checkout — unrelated to the design/viewer work here. Worth a separate pass.
- **Minor cosmetic:** a thin redundant "Status bar" panel still docks at the top
  on some launches (panel-layout remnant); the real status bar is at the bottom.
- **Design modules still open** (see `design_prompt.md`): scope editor, MCP
  activity, crop, color tools, slideshow, metadata, gallery strip, settings,
  themes, multi-monitor. Core (#1 File Panel + #2 Canvas) is done.

See `new_docs.md` for architecture, build/run, and repo layout.
