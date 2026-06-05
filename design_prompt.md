# ImageGlass for Mac — Design Brief

Prompts for an AI UI design tool (Claude design / similar). Feed the **Master
Brief** first to set global style, then design **one module at a time** using
the numbered prompts. Each module prompt is self-contained — paste the Master
Brief's STYLE section above it if the tool loses context between sessions.

---

## Master Brief (paste first, every session)

```
Design a macOS-native desktop app: "ImageGlass for Mac" — a fast, clean image
viewer for reviewing UI-design mockups.

WHO / WHY
A product lead opens 400+ design screenshots scattered across many project
folders, filters out junk (dark-mode / low-quality variants), and clicks
through them rapidly in live meetings to give feedback. Speed and clarity are
the entire point — off-the-shelf viewers choke at this scale. An AI assistant
(via an MCP server) can also drive the app: set which folders are in scope,
push filter rules, and trigger re-scans from outside the app.

PLATFORM & STYLE (applies to EVERY screen)
- Native macOS (Sonoma / Sequoia), built in SwiftUI + AppKit.
- Feels first-class Mac: unified title bar, vibrancy / material sidebars,
  SF Symbols icons, system accent color, full light + dark mode.
- Tone: calm, neutral, content-first — like Apple Preview.app and Xcode. The
  IMAGE is the hero; chrome recedes. Neutral page-gray canvas behind images.
  No loud brand colors, no gradients competing with content.
- Only standard macOS controls: NavigationSplitView, List / OutlineGroup,
  NSOutlineView, Table, toolbar, popovers, sheets, inspector panels.
- Performance-minded: assume hundreds of rows + thumbnails. Virtualized
  scrolling, lazy thumbnails, light per-row decoration.

GLOBAL WINDOW SHELL (the frame every module lives in)
- Left: collapsible sidebar (~300pt) — the file panel.
- Center: image canvas on neutral gray.
- Right: optional inspector column for panels (metadata, histogram, etc.).
- Top: sparse toolbar. Bottom: slim status bar ("13 files · evaluated 28s ago"
  · current path).
- The app is PANEL-BASED: regions host dockable / tabbed / floating panels the
  user can rearrange. Design the shell so panels can mount in left, right,
  bottom, or float free.

Always render real-looking sample content: a folder tree like
"jfk-social / feed-page / feed_01.png", believable design screenshots in the
canvas, real-looking counts. Deliver light AND dark mode for each screen.
```

---

## 1. File Panel — list + tree (primary sidebar)

```
Design the left File Panel. It resolves a "scope" (a set of folders + filter
rules) into a file list. Five view modes, switchable via a segmented control:
1. STRIP    — single horizontal/vertical thumbnail strip, compact.
2. GRID     — thumbnail grid, adjustable thumb size.
3. DETAILS  — table: thumbnail, filename, size, dimensions, modified date,
              sortable column headers.
4. TREE     — folder hierarchy grouped by source root, expand/collapse
              disclosure rows, folder + image-type icons, small thumbnails,
              filename labels.
5. COLUMN   — Finder-style miller columns.
Footer shows "<n> files · evaluated <time> ago" and the active scope name.
Show hover, selected (accent highlight), and focused row states. Show a search/
filter field. Selected file drives the canvas. Render in tree mode AND details
mode, light + dark.
```

## 2. Image Canvas — viewer

```
Design the center image canvas. Selected image centered on neutral page-gray.
Pinch-zoom + pan. Floating, auto-hiding control cluster bottom-center: fit,
100%, fill, zoom +/−, rotate, flip, and a zoom-% readout. Six zoom modes
(auto, lock, scale to width / height / fit / fill). Slim bottom status bar:
filename + full path + dimensions + zoom %. Show: a loaded design screenshot,
the zoom overlay visible, and an empty state ("No image selected"). Light +
dark.
```

## 3. Scope Editor + Local Storage

```
Design the Scope Editor panel. A "scope" = named set of SOURCE folders +
include rules (extensions, globs) + EXCLUDE rules (e.g. exclude filenames
containing "_dark_" or "_dn_"). Show:
- A list of named scopes (sidebar) with the active one selected.
- For the active scope: editable list of root folders (add via folder picker),
  include-extensions chips, include/exclude glob rules, recursive toggle.
- A "Re-evaluate" button + last-evaluated timestamp + resolved file count.
- A note that these persist as plain-text files on disk (Local Storage) and can
  also be edited by an AI assistant via MCP.
Also design a compact "Local Storage" panel showing the on-disk scope files
(directories.yaml-style) read-only, with last-evaluated time and the resolved
list. Light + dark.
```

## 4. MCP Activity panel

```
Design an "MCP Activity" panel: a live log of Model Context Protocol calls an
AI assistant makes to drive the app (e.g. "add_root_directory",
"set_filter_criteria", "reevaluate_scope", "select_file"). Show timestamped
rows with tool name, arguments summary, and result/status. A connection
indicator (server running / client connected). Calm, monospaced, log-like but
native. Light + dark.
```

## 5. Crop tool

```
Design the Crop panel + on-canvas crop overlay. Draggable crop rectangle with
corner/edge handles, rule-of-thirds grid, dimming outside the selection. Side
panel: aspect-ratio presets (free, 1:1, 4:3, 16:9, original), numeric X/Y/W/H
fields, and Apply / Cancel. Note JPEG-lossless crop support. Light + dark.
```

## 6. Color picker + color channels + histogram

```
Design three related inspector panels:
- COLOR PICKER: eyedropper readout of the hovered pixel — swatch + value in
  multiple formats (HEX, RGB, HSL, HSB), copy button.
- COLOR CHANNELS: toggles to isolate/view R, G, B, A, and luminance channels of
  the current image.
- HISTOGRAM: RGB + luminance histogram of the current image.
Compact, dockable to the right inspector column. Light + dark.
```

## 7. Frame navigation + video + SVG

```
Design playback controls for multi-frame and motion content:
- FRAME NAV: for animated GIF / APNG / multi-frame TIFF — play/pause, prev/next
  frame, frame counter (e.g. "12 / 48"), a scrubber, "save this frame" / "export
  all frames".
- VIDEO: for embedded motion photos (Live Photos / motion JPEG) — play/pause,
  timeline scrubber, mute.
- SVG: vector rendering with a toggle for animated SVG play/pause.
Controls overlay the canvas, auto-hide. Light + dark.
```

## 8. Slideshow mode

```
Design fullscreen slideshow mode: image centered on black, auto-advance with a
countdown timer indicator, prev/next, play/pause, interval setting, and an
exit affordance. Minimal chrome that fades away. Light + dark (dark dominant).
```

## 9. Metadata / Image Info

```
Design a metadata inspector: EXIF + file info for the current image — camera,
lens, exposure, ISO, dimensions, color space, file size, created/modified
dates, full path. Grouped sections, copyable values, search within metadata.
Dockable right inspector. Light + dark.
```

## 10. Gallery strip

```
Design a "gallery strip" panel: a thin horizontal filmstrip of thumbnails for
the resolved file list, docked to the bottom, with the current image
highlighted, smooth horizontal scroll, and keyboard prev/next. Built for fast
click-through during meetings. Light + dark.
```

## 11. Panel system — docking / tabbing / floating

```
Design the modular panel-management UX. Panels (file panel, scope editor,
metadata, histogram, color picker, crop, gallery strip, MCP activity, etc.) can
be: docked left/right/bottom, grouped into TAB GROUPS, resized via splitters,
or torn off into FLOATING windows. Show: a tab group with multiple panel tabs,
a drag-to-dock affordance with drop-zone highlights, and a "panels" menu to
toggle each panel on/off. Show a saved-layout / reset-layout control. Light +
dark.
```

## 12. Settings / Preferences

```
Design the Preferences window (tabbed, standard macOS): General, Appearance
(light/dark/system + theme pack + icon pack), File List (default view mode,
sort, thumbnail size), Viewer (default zoom mode, interpolation, background),
Panels (default layout), Formats (enable/disable extensions), MCP (server
on/off, transport), Advanced. Standard macOS settings layout with a toolbar of
tabs. Light + dark.
```

## 13. Themes / appearance

```
Design the theme/appearance picker: a gallery of theme packs (preview
swatches), icon-pack selection, accent color, and light/dark/auto toggle, with
a live preview of the app chrome. Light + dark.
```

## 14. Multi-monitor / second viewer / floating tree

```
Design the multi-display story: a "Second Viewer" — a clean image-only window
(no chrome) that mirrors the current selection, meant for a second display
during presentations. And a detached "Floating File Tree" window holding just
the file panel, so the presenter can navigate on one screen while the audience
sees the image on another. Show both windows alongside the main window. Light +
dark.
```

## 15. About + Releases/News + empty/first-run

```
Design supporting screens:
- ABOUT: app name, version, credits, GPLv3 license note, links.
- RELEASES & NEWS: a changelog / update-available panel.
- FIRST-RUN / EMPTY STATE: no scope yet — a friendly prompt to "Add a folder"
  or "Let your AI assistant set up a scope," explaining the scope concept.
Light + dark.
```

---

## How to use

1. Paste the **Master Brief** into the design tool.
2. Pick a module (start with #1 File Panel and #2 Canvas — the core).
3. Paste that module's prompt; iterate until the screen is right.
4. Move to the next module. Keep the same style by re-pasting the Master
   Brief's STYLE/SHELL section if the tool loses context.
5. Take approved layouts/components back into the SwiftUI code module by module.

Reference: see `new_docs.md` (architecture) and `docs/*.mdx` (per-feature specs)
for exact behavior behind each screen.
