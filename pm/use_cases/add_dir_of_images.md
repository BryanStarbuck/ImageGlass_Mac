---
title: Use Case — Adding a Second Root Directory via the Directories Menu
description: Hyper-detailed user-scenario spec for the Directories → Add Directory… menu flow when one root is already registered. Walks every step a tester (or XCUITest run) must perform — the menu open, the NSOpenPanel pick, the YAML mutation, the background walk, the `walkerRoots` snapshot refresh, the SwiftUI re-render — and pins down the exact on-screen and on-disk outcomes that prove the new directory landed as a peer at the top of the file tree (not as a descendant, not as a replacement, not nowhere). Includes the specific failure that motivated this spec (after adding a second directory and collapsing the first root, the second root is not visible as a peer) and lists the failure modes that must be surfaced so a test can catch a regression.
---

# Use Case — Adding a Second Root Directory via the Directories Menu

This page is the **step-by-step user-scenario spec** for one very
specific interaction: the user already has one root directory in the
file tree panel; they pull down the **Directories** menu, choose
**Add Directory…**, pick a different directory hierarchy (which
contains many image files) from the `NSOpenPanel`, and expect to find
that hierarchy as a **second peer node at the top of the file tree**,
sibling to the first root.

The companion document for the broader MCP-driven tour is
[`mcp_file.mdx`](./mcp_file.mdx). This document only covers the
**GUI-driven, menu-driven** add-second-root flow and treats it with the
granularity needed to write a regression test against it.

The spec is written so that:

* A human running through the steps can answer **yes / no** at every
  verify step.
* An automated XCUITest harness can drive the same steps via
  `XCUIApplication`, `XCUIElement.menuItem`, `NSOpenPanel`
  programmatic selection, and `cat ~/Library/Application\ Support/ImageGlass_Mac/directories.yaml`.
* A developer reading the spec can decide whether the
  symptom they are seeing ("the second root is missing after I add
  it") matches a known failure mode in §6 or whether it is a brand new
  bug worth filing.

---

## 0. Common Preconditions

These hold for every section below unless explicitly overridden.

* The app is built from the current branch and signed (or runs from
  Xcode in Debug). First launch has already happened at least once so
  the `~/Library/Application Support/ImageGlass_Mac/` directory tree
  exists.
* The application support layout (per
  [`mcp_file.mdx`](./mcp_file.mdx) §0):

  ```
  ~/Library/Application Support/ImageGlass_Mac/
  ├── directories.yaml         # the file tree panel's root-directory list
  ├── selection.txt            # MCP `select_file` channel (not used here)
  ├── panel_view_mode.txt      # MCP `panel.set_view_mode` channel
  ├── heartbeat.txt            # PID heartbeat for the MCP sidecar
  └── logs/
      └── log.log              # every MCP call + every directory-walker event
  ```

* The file panel is **visible**. (`settings.json` →
  `layout.show_file_panel = true`, the default after first launch.) If
  it is hidden, surface it via the title-bar `sidebar.left` button or
  via **View → Show Files Panel** (⌘L) before starting the scenario.
* The file panel is in **Tree** view mode. (Top of the panel, the
  segmented `List | Tree` picker. Tree is the default after first
  launch.) If it is in List view, click `Tree` before starting.
* The viewer canvas already shows an image — the one auto-selected by
  the first root's walk (per [`mcp_file.mdx`](./mcp_file.mdx) §10), or
  one the user clicked since. **The viewer is NOT empty.** This
  matters because the `panel.auto_select_first` rule in §10.1 of
  `mcp_file.mdx` is *suppressed* when the viewer is not empty; the
  second root's walk must therefore land in the tree **without**
  yanking the viewer's focus.
* Two real test fixtures on disk. Each is an absolute path with at
  least a handful of `.jpg` / `.png` / `.heic` files somewhere
  underneath (depth ≥ 1 is fine; depth ≥ 2 with multiple
  subdirectories is the more interesting case the user described —
  *"a directory that's a hierarchy. It has a lot of image files
  underneath that hierarchy"*).

  ```
  FIRST_ROOT  =  ~/Pictures/tour/beach
  SECOND_ROOT =  ~/BGit/work/into_Work/StarbuckLabs/JFK/UX
  ```

  Both must exist, both must be readable, neither must be a
  descendant of the other (the spec covers the peer case; nested
  roots are an explicit non-goal — see §6.5).

* "Verify" steps are concrete: read a file, look at a row of pixels,
  read a log line. Each one is a check a human or an XCUITest run can
  perform.

---

## 1. Precondition — One Root Already Registered

This section pins down the **starting state** every subsequent section
assumes. It is *not* the scenario under test; it is the setup.

### 1.1 Actions, in order

1. Launch the app.
2. From the menu bar choose **Directories → Add Directory…** (default
   hotkey ⌥⌘D, see [`list_of_files.mdx`](../list_of_files.mdx#3a8-directories-menu-and-hotkeys)).
3. In the `NSOpenPanel`, navigate to `FIRST_ROOT` (e.g.
   `~/Pictures/tour/beach`). Single-click it once to highlight it.
4. Click the panel's primary button (labeled **Add** — set by
   `panel.prompt = "Add"` in `addDirectoryFromPicker` at
   `code/Sources/ImageGlass/ImageGlassApp.swift:284`).

### 1.2 Expected on-disk state

After step 4 the GUI runs three things in order, all from
`addDirectoryFromPicker` (`code/Sources/ImageGlass/ImageGlassApp.swift:279`):

1. `DirectoriesStore.shared.addRoot(path: url.path)` — canonicalizes
   the path (`URL(fileURLWithPath:).standardizedFileURL` then
   `.resolvingSymlinksInPath()` if the path exists), then under
   `lock.lock()` loads the current YAML, appends a `RootDirectory`
   entry, and atomically writes the YAML back (`code/Sources/ImageGlassCore/Storage/DirectoriesStore.swift:92`).
2. `MCPAuditLogger.shared.logDirectoryToolCall(toolName: "add_directory", …)` — appends one
   `ts=… tool=mcp.add_directory path=<canonical> client=gui corr=<id> ok=true`
   line to `logs/log.log`.
3. `DirectoryTreeWalker.shared.scheduleWalk(root: url, filter: .empty, corr: corr)` —
   posts a background `Task` that walks the hierarchy depth-first /
   lexicographic (`code/Sources/ImageGlassCore/FileList/DirectoryTreeWalker.swift:64`).

```sh
cat ~/Library/Application\ Support/ImageGlass_Mac/directories.yaml
```

must read approximately:

```yaml
schema_version: 1
root_directories:
  - path: /Users/<you>/Pictures/tour/beach
    filter:
      match: any
      items: []
    last_walked: 2026-06-05T…Z
```

### 1.3 Expected on-screen state

* The file panel's Tree view shows **one** top-level expandable row
  whose label is the last path component of `FIRST_ROOT` (e.g.
  `beach`). The chevron is `▾` (expanded) — every newly-added root
  defaults to expanded (`DesignTreeNode.init`, see
  `code/Sources/ImageGlass/FileList/DesignTreeNode.swift:23`).
* Immediately under the root row, indented by `depth * 14 pt`, are
  the visible image files / sub-directories from the walk.
* The viewer canvas shows the first image found by the depth-first
  lexicographic walker (per `mcp_file.mdx` §10) — the auto-select
  rule fires because the viewer was empty at app launch.
* Status bar reads `<N> files` where N is the count of files in
  `FIRST_ROOT` that pass the built-in file-kind filter
  (`image`, `svg`, `video`).

### 1.4 Verify

* On disk: `directories.yaml` has exactly **one** entry in
  `root_directories[]`.
* On screen: exactly **one** top-level row in the file tree. Its
  chevron is `▾`. The viewer is non-empty.
* On disk:

  ```sh
  grep -E "tool=mcp.add_directory|app=directory.walk" \
      ~/Library/Application\ Support/ImageGlass_Mac/logs/log.log \
      | tail -n 2
  ```

  prints two lines sharing one `corr=<id>`: one
  `tool=mcp.add_directory … ok=true`, one
  `app=directory.walk path=<FIRST_ROOT canonical> count=<N>
  elapsed_ms=<…>`.

If any of §1.4's checks fail, **stop**. The scenario under test
(§2 onward) is impossible to evaluate from a broken starting state.

---

## 2. Scenario — Add the Second Root via the Directories Menu

This is the scenario the user reported failing. Every step below is a
deliberate, observable action; nothing is skipped because "it's
obviously the same as §1."

### 2.1 Actions, in order

1. From the menu bar, pull down the **Directories** menu. The menu is
   declared in `ImageGlassApp.directoriesMenuCommands` at
   `code/Sources/ImageGlass/ImageGlassApp.swift:189`. The menu items, in
   order, are:

   * **Add Directory…**           (⌥⌘D)
   * **Add Directory from Path…** (⌥⌘⌃D)
   * (divider)
   * **Registered Directories (1)** → submenu showing the one root
     from §1, with a Reveal / Remove pair.
   * (divider)
   * **Refresh All**              (⌥⌘R)
   * **Reveal in Finder**         (⌥⌘O)

   The user must specifically choose the first item. The submenu
   **Registered Directories (1)** is not the right place — it only
   manages existing roots.

2. Click **Add Directory…**. An `NSOpenPanel` appears with
   `canChooseFiles = false`, `canChooseDirectories = true`,
   `allowsMultipleSelection = true`, `prompt = "Add"`
   (`code/Sources/ImageGlass/ImageGlassApp.swift:279`). The panel is
   modal; the main window is dimmed underneath.

3. In the panel, navigate to `SECOND_ROOT`
   (e.g. `~/BGit/work/into_Work/StarbuckLabs/JFK/UX`). Single-click it
   to highlight. Do **not** double-click — double-click drills into
   the directory and the user would end up adding a *descendant* of
   `SECOND_ROOT` instead of `SECOND_ROOT` itself, which is a
   user-error class that the spec does not cover but a test should
   note so the failure is recognized for what it is.

4. Click **Add**.

### 2.2 What the code is expected to do in response

Concrete, in source order. The numbered steps below are the
contractual steps; if any one of them does not run, the scenario
fails.

1. `for url in panel.urls { … }` —
   `code/Sources/ImageGlass/ImageGlassApp.swift:286`. The loop iterates
   the (one) URL the user picked. Multiple-selection is supported but
   not required for this scenario.

2. `let (canonical, already) = try DirectoriesStore.shared.addRoot(path: url.path)` —
   `code/Sources/ImageGlassCore/Storage/DirectoriesStore.swift:92`. The
   store **canonicalizes** the path (`URL.standardizedFileURL` +
   `.resolvingSymlinksInPath()` when the path exists), then under
   `lock.lock()` performs *load → idempotency check → append → save*
   as one atomic critical section. Concrete result:

   * `directories.yaml` is rewritten atomically (temp file + rename)
     so it now contains **two** entries in
     `root_directories[]`: `FIRST_ROOT` (from §1) and `SECOND_ROOT`.
   * The return is `(canonical: URL, alreadyExisted: Bool)`.
     `alreadyExisted` is **false** because `SECOND_ROOT` is new.

3. `if !already { … }` — gates the audit log + scheduled walk on a
   genuinely-new entry. For our scenario this branch runs.

4. `MCPAuditLogger.shared.logDirectoryToolCall(toolName: "add_directory", path: url.path, client: "gui", corr: corr, ok: true)` —
   appends one line to `logs/log.log` of the shape
   `ts=… tool=mcp.add_directory path=<SECOND_ROOT> client=gui corr=<id> ok=true`.

5. `DirectoryTreeWalker.shared.scheduleWalk(root: url, filter: .empty, corr: corr)` —
   `code/Sources/ImageGlassCore/FileList/DirectoryTreeWalker.swift:64`. The
   walker:

   * Hops onto its serial queue.
   * Cancels any in-flight walk **for the same URL key** (none, for
     a fresh add).
   * Spawns a detached `Task` running `runWalk(root:filter:corr:)`.
   * Stores the `Task` in `inflight[url]` so a subsequent
     re-schedule for the same root would cancel it.

6. `runWalk` (`code/Sources/ImageGlassCore/FileList/DirectoryTreeWalker.swift:148`)
   does, in order:

   * `logger.logTreeWalkStart(path: root.path, corr: corr)` — emits
     `ts=… app=directory.walk_start path=<SECOND_ROOT> corr=<id>`.
   * `Self.walkSync(root: root, filter: filter)` — synchronous,
     recursive walk via `FileManager.contentsOfDirectory` +
     `.skipsHiddenFiles`. Returns a `WalkResult { tree, fileCount,
     firstImage }`. The walker sorts children **lexicographically**
     (`code/Sources/ImageGlassCore/FileList/DirectoryTreeWalker.swift:263`)
     and recurses depth-first, so the produced `tree` is deterministic.
   * `queue.sync { self.roots[root] = RootDirectory(…); self.inflight[root] = nil }` —
     commits the new root to the walker's in-memory dictionary
     `[URL: RootDirectory]`.
   * `try? store.setLastWalked(path: root, at: Date())` — updates
     `last_walked` in `directories.yaml`.
   * `traverseAndLog` — one `tree.node` log line per node found
     (directory or file). On a deep hierarchy this is a lot of lines.
   * `logger.logDirectoryWalk(path:count:elapsedMs:corr:)` — emits
     the closing `ts=… app=directory.walk path=<SECOND_ROOT>
     count=<N> elapsed_ms=<…> corr=<id>` line.
   * `NotificationCenter.default.post(name: didChangeNotification, object: root)` —
     fires the GUI's refresh hook.
   * **The §10 first-image auto-select rule does NOT fire** because
     `viewerIsEmpty == false` (the user already has an image loaded
     from §1). `firstImageFoundNotification` is suppressed.
     `selectedFile`, `panelViewMode`, and `panelLayout` are left
     untouched. The viewer continues to display the same image that
     was on screen before §2 began.

7. The GUI observer
   `AppState.startDirectoryTreeWalkerObserver`
   (`code/Sources/ImageGlass/AppState.swift:721`) catches the
   `didChangeNotification`:

   ```swift
   directoryDidChangeToken = NotificationCenter.default.addObserver(
       forName: DirectoryTreeWalker.didChangeNotification,
       object: nil,
       queue: .main
   ) { [weak self] _ in
       Task { @MainActor in
           guard let self else { return }
           self.walkerRoots = DirectoryTreeWalker.shared.snapshot()
       }
   }
   ```

   It calls `DirectoryTreeWalker.shared.snapshot()` —
   `code/Sources/ImageGlassCore/FileList/DirectoryTreeWalker.swift:133`:

   ```swift
   public func snapshot() -> [RootDirectory] {
       var copy: [RootDirectory] = []
       queue.sync { copy = Array(self.roots.values) }
       return copy
   }
   ```

   and assigns the result to `state.walkerRoots`. Because `AppState`
   is `@Observable` and `walkerRoots` is a stored property, every
   SwiftUI view that reads `state.walkerRoots` re-renders.

8. `DirectoryFilenamePanel.walkerTreeView`
   (`code/Sources/ImageGlass/DirectoryFilenamePanel.swift:360`)
   reads `state.walkerRoots`, projects each entry through
   `DirectoryFilenamePanel.buildView` into a `NodeView`, and renders
   them as **peers in a `LazyVStack`**:

   ```swift
   private var walkerTreeView: some View {
       let roots: [NodeView] = state.walkerRoots.compactMap { root in
           guard let tree = root.tree else { return nil }
           return Self.buildView(node: tree, parentPath: root.path)
       }
       return ScrollView {
           LazyVStack(spacing: 2) {
               ForEach(roots) { root in
                   DesignTreeNode(node: root, depth: 0,
                                  selected: $state.selectedFile,
                                  matches: matchesSearch)
               }
           }
           .padding(.horizontal, 8)
           .padding(.vertical, 8)
       }
   }
   ```

   Each `DesignTreeNode` initialised with `depth: 0` starts
   `expanded = true` (`code/Sources/ImageGlass/FileList/DesignTreeNode.swift:23`,
   `State(initialValue: depth <= 1)`).

9. The `AppState.startDirectoriesFileWatcher`
   (`code/Sources/ImageGlass/AppState.swift:792`) watches the app
   support directory and also receives a Darwin distributed
   notification when the MCP server writes `directories.yaml`. It
   calls `reloadDirectoriesFromDisk()`
   (`code/Sources/ImageGlass/AppState.swift:842`) which diffs the
   on-disk YAML against the walker's in-memory snapshot:

   * New root → `scheduleWalk` (background walk + FS watch).
   * Removed root → `removeRoot`.
   * Filter changed → `refilter`.

   For our scenario the GUI itself wrote the YAML and already
   scheduled the walk, so the reconcile is expected to be a **no-op**
   (the walker already contains, or is about to contain, the same
   entry the YAML lists). The contract for this section: the
   reconcile must not remove the just-added root, must not add a
   duplicate of it, and must not re-walk it unnecessarily.

   **NOTE — known sharp edge.** This reconcile compares walker keys
   (the URL the GUI passed verbatim to `scheduleWalk`) against the
   YAML's *canonical* paths. If those two URLs are not byte-identical
   (e.g. `panel.urls[0]` returns a URL whose `.path` differs from
   the canonical form returned by `DirectoriesStore.canonicalize`),
   the reconcile will (a) schedule a second walk for the canonical
   URL, and (b) remove the entry under the non-canonical URL. The
   second walk eventually lands and the steady state is correct, but
   between the two events there can be a window in which the
   just-added root **disappears** from `state.walkerRoots`. §6.6
   covers this failure mode.

### 2.3 Expected on-disk state

After step 5 of §2.2:

```sh
cat ~/Library/Application\ Support/ImageGlass_Mac/directories.yaml
```

must read approximately:

```yaml
schema_version: 1
root_directories:
  - path: /Users/<you>/Pictures/tour/beach
    filter:
      match: any
      items: []
    last_walked: 2026-06-05T…Z
  - path: /Users/<you>/BGit/work/into_Work/StarbuckLabs/JFK/UX
    filter:
      match: any
      items: []
    last_walked: 2026-06-05T…Z
```

The two entries are in **append order**. `FIRST_ROOT` is the first
entry (it was added first in §1); `SECOND_ROOT` is the second entry.
This append order is the contract of `DirectoriesStore.addRoot`
(`code/Sources/ImageGlassCore/Storage/DirectoriesStore.swift:100` —
`file.roots.append(...)`).

### 2.4 Expected on-screen state

* The file panel's Tree view shows **exactly two** top-level
  expandable rows:

  ```
  ▾ beach                       (FIRST_ROOT)
      <files / sub-directories of FIRST_ROOT, indented>
  ▾ UX                          (SECOND_ROOT)
      <files / sub-directories of SECOND_ROOT, indented>
  ```

  Both chevrons are `▾` (expanded). Both rows are **peers** —
  they share the same `padding(.leading, depth * 14)` with `depth = 0`
  (i.e. no leading indent beyond the panel's 8 pt horizontal padding),
  so they line up visually. Neither row is nested under the other.

* The viewer canvas continues to show whatever image the user had
  selected before §2 began. **The selection is unchanged.** Adding a
  second root does not move the viewer's focus.

* Status bar updates to show the new total file count
  (FIRST_ROOT files + SECOND_ROOT files, both after the built-in
  file-kind filter, both after any search text in the panel header).

* The panel's header `View` picker stays on `Tree`. The header search
  field is unchanged. The viewMode is preserved.

### 2.5 Verify

* **The hero check.** With the panel scrolled to the top, both root
  rows must be visible. Click the chevron on the first row to
  collapse `FIRST_ROOT`. The view should re-flow with
  `FIRST_ROOT` as a one-line collapsed row at the top and
  `SECOND_ROOT` immediately below it as an expanded peer.

* **The user's specific complaint.** *"I collapse the original top
  root directory, and I am expecting to find a peer, which is the new
  root directory I just added, but that's failing."* The correct
  passing behavior: after the collapse, two rows are visible at the
  panel's top level:

  ```
  ▸ beach
  ▾ UX
      <files of UX>
  ```

  If, after collapsing `FIRST_ROOT`, the panel shows only the
  collapsed `▸ beach` row and nothing else — **the bug is reproduced**.
  Cross-reference §6 to identify the failure mode.

* **On-disk verify:**

  ```sh
  cat ~/Library/Application\ Support/ImageGlass_Mac/directories.yaml
  ```

  contains the two entries described in §2.3.

* **MCP audit verify:**

  ```sh
  grep -E "tool=mcp.add_directory|app=directory.walk" \
      ~/Library/Application\ Support/ImageGlass_Mac/logs/log.log \
      | tail -n 4
  ```

  prints four lines (two `tool=mcp.add_directory` and two
  `app=directory.walk`), one pair per root. The pairs are joined by
  `corr=`.

* **Snapshot count verify (developer-mode).** Set a breakpoint on
  `AppState.startDirectoryTreeWalkerObserver` line 741
  (the `self.walkerRoots = DirectoryTreeWalker.shared.snapshot()`
  assignment) and step through. Immediately after the second walk
  completes, the snapshot must have `count == 2`. If it has
  `count == 1`, the walker is missing the second root — cross-reference
  §6.2, §6.3, §6.6.

---

## 3. Re-Open the Picker for Idempotency Sanity (Optional)

This is a **defensive** sub-scenario: the user accidentally selects
`SECOND_ROOT` a second time. The system must NOT show a duplicate
top-level row.

### 3.1 Actions, in order

1. From the menu bar, choose **Directories → Add Directory…**.
2. In the panel, navigate again to `SECOND_ROOT`.
3. Click **Add**.

### 3.2 Expected result

* `DirectoriesStore.addRoot` returns
  `(canonical, alreadyExisted: true)` — see line 97 of
  `DirectoriesStore.swift`:

  ```swift
  if file.roots.contains(where: { $0.path == canonical }) {
      return (canonical, true)
  }
  ```

* The GUI's `if !already { … }` gate prevents the audit log line
  and the `scheduleWalk`.

* `directories.yaml` is unchanged (still two entries).

* The on-screen file tree is unchanged (still two top-level rows).

* No new log line is emitted.

### 3.3 Verify

* `wc -l < ~/Library/Application\ Support/ImageGlass_Mac/logs/log.log`
  is **the same** before and after.

* `cat directories.yaml | grep -c "^  - path:"` returns `2`.

If a third top-level row appears, the idempotency contract in
`DirectoriesStore.swift:97` is broken — file a separate bug, not the
one this spec is for.

---

## 4. Collapse / Expand Sanity

The user's complaint specifically named the collapse action:
*"I collapse the original top root directory, and I am expecting to
find a peer."* This section pins down the contract of the chevron
click.

### 4.1 Actions, in order

1. From the §2 steady state (two top-level rows, both expanded), click
   the chevron on the `FIRST_ROOT` row.

### 4.2 Expected result

* `DesignTreeNode.directoryRow.onTapGesture`
  (`code/Sources/ImageGlass/FileList/DesignTreeNode.swift:60`) fires.
  Inside `withAnimation`, `expanded.toggle()` runs. For the
  `FIRST_ROOT` instance this flips `expanded` from `true` to `false`.

* SwiftUI re-renders that one `DesignTreeNode`. Inside its body,
  the `if expanded { ForEach(visibleChildren) { … } }` branch falls
  away. The directoryRow remains visible (the chevron is now `▸`).

* **The other `DesignTreeNode` instance — `SECOND_ROOT`'s — is not
  re-rendered with new identity.** It is a sibling node in the same
  `LazyVStack` `ForEach`, keyed by `NodeView.id` (which is the root's
  path). Its `@State expanded` is preserved. It remains expanded.

* Net result on screen:

  ```
  ▸ beach                       <-- collapsed
  ▾ UX                          <-- still expanded
      <files of UX>
  ```

### 4.3 Verify

* On screen: `▸ beach` is at the top. `▾ UX` is immediately below it
  (with the `UX` files indented under it). Two top-level rows are
  visible.

* Clicking `▸ beach` again toggles `FIRST_ROOT` back open and the
  earlier ordering returns.

If after collapsing `FIRST_ROOT` no second row appears, see §6.4 —
the most-likely cause is that `walkerRoots.count == 1` (the second
root never landed in the snapshot), so SwiftUI was only ever
rendering one row in the first place. The "collapse" is not the
event that lost the second root; the second root was already missing.

---

## 5. Source-File Reference

The contract spelled out in §1–§4 is implemented across the following
files. A regression test should set breakpoints in these spots when
diagnosing a failure.

| Concern | Source location |
| --- | --- |
| `Directories` menu definition | `code/Sources/ImageGlass/ImageGlassApp.swift:189` (`directoriesMenuCommands`) |
| `Add Directory…` menu item | `code/Sources/ImageGlass/ImageGlassApp.swift:192` |
| `NSOpenPanel` invocation | `code/Sources/ImageGlass/ImageGlassApp.swift:279` (`addDirectoryFromPicker`) |
| YAML store + canonicalization | `code/Sources/ImageGlassCore/Storage/DirectoriesStore.swift:92` (`addRoot`), 178 (`canonicalize`) |
| MCP audit log line shape | `code/Sources/ImageGlassCore/Logging/MCPAuditLogger.swift` |
| Walker schedule + walk | `code/Sources/ImageGlassCore/FileList/DirectoryTreeWalker.swift:64` (`scheduleWalk`), 148 (`runWalk`), 234 (`walkSync`) |
| In-memory roots dictionary | `code/Sources/ImageGlassCore/FileList/DirectoryTreeWalker.swift:44` |
| Snapshot order | `code/Sources/ImageGlassCore/FileList/DirectoryTreeWalker.swift:133` (`snapshot()` → `Array(self.roots.values)`) |
| `didChangeNotification` | `code/Sources/ImageGlassCore/FileList/DirectoryTreeWalker.swift:21` |
| GUI observer that re-pulls snapshot | `code/Sources/ImageGlass/AppState.swift:721` (`startDirectoryTreeWalkerObserver`) |
| File-watcher reconcile | `code/Sources/ImageGlass/AppState.swift:842` (`reloadDirectoriesFromDisk`) |
| Tree-view body | `code/Sources/ImageGlass/DirectoryFilenamePanel.swift:360` (`walkerTreeView`) |
| Per-root view projection | `code/Sources/ImageGlass/DirectoryFilenamePanel.swift:599` (`buildView`) |
| Root row + expansion state | `code/Sources/ImageGlass/FileList/DesignTreeNode.swift:23` (`init`, `_expanded = State(initialValue: depth <= 1)`) |
| Visibility gate | `code/Sources/ImageGlass/FileList/DesignTreeNode.swift:29` (`if hasVisibleDescendant`) |

---

## 6. Failure Modes the Scenario Must Surface

A regression test for this scenario should be able to **name** the
failure mode it just observed. Each entry below pairs a symptom with
the most-likely root cause and the smallest verify step that
distinguishes it from neighboring failure modes.

### 6.1 No second row at all — the YAML is also missing the second entry

* **Symptom.** After §2's add, the file tree shows one row. After §4's
  collapse, nothing else appears.
* **Root cause class.** The `NSOpenPanel` flow never wrote the second
  entry to disk.
* **Distinguishing verify.** `cat directories.yaml` shows one entry,
  not two. `grep tool=mcp.add_directory logs/log.log | wc -l` returns
  `1` (just the §1 add).
* **Implication.** The bug is in the GUI → store path
  (`addDirectoryFromPicker` returned before `addRoot` ran, or
  `addRoot` threw and the catch branch logged `ok=false`).

### 6.2 No second row, but the YAML has two entries

* **Symptom.** `directories.yaml` has two entries (verifies §2.3), but
  the file tree shows one row.
* **Root cause class.** The walker never finished walking the second
  root, **or** the snapshot was never re-read into
  `state.walkerRoots`.
* **Distinguishing verify.** `grep app=directory.walk
  logs/log.log` returns one line (just `FIRST_ROOT`), not two. If
  `directory.walk_start` appears for `SECOND_ROOT` but
  `directory.walk` (the closing line) does not, the walk hung or
  was cancelled. If both `directory.walk` lines are present,
  `state.walkerRoots = DirectoryTreeWalker.shared.snapshot()` never
  fired (the `didChangeNotification` observer is broken — see §6.3).

### 6.3 Both walks completed, but `walkerRoots.count == 1`

* **Symptom.** Both `app=directory.walk` lines are in `logs/log.log`,
  but the file tree shows one row. A breakpoint at
  `AppState.swift:741` shows `walkerRoots.count == 1`.
* **Root cause class.** The walker's `roots` dictionary lost one
  entry, **or** the snapshot is racing with a remove.
* **Distinguishing verify.** Set a watchpoint on
  `DirectoryTreeWalker.roots` (line 44 of `DirectoryTreeWalker.swift`)
  to log every mutation. The expected sequence after §2:
  insert `FIRST_ROOT`, insert `SECOND_ROOT`. If a `remove`
  appears in between or after, that is the bug. Cross-reference §6.6
  for the canonicalization-mismatch flavour of this failure.

### 6.4 Both roots in `walkerRoots`, only one rendered

* **Symptom.** `walkerRoots.count == 2`, but the SwiftUI panel
  renders one row.
* **Root cause class.** Either the second root has `tree == nil`
  (compact-mapped out in `walkerTreeView` line 366), or its
  `hasVisibleDescendant` returns `false`
  (`DesignTreeNode.swift:132`) and the whole VStack is therefore
  empty (`DesignTreeNode.swift:29` — `if hasVisibleDescendant`).
* **Distinguishing verify.** Print `state.walkerRoots[1].tree` from
  the debugger. If `nil`, the walker recorded the root but failed to
  store its tree (the walk threw mid-way; check the
  `traverseAndLog` line count for that root vs. the
  `directory.walk count=N` field). If non-nil, manually evaluate
  `anyVisibleDescendant` against the projected `NodeView` to see why
  every descendant filtered out (search text was set? The user
  typed something into the FILES search box? A global filter is in
  effect from a stale §6 / §7 MCP call?).

### 6.5 Both roots rendered, but one is a descendant of the other

* **Symptom.** The two top-level rows are NOT visually peers — the
  second one indents under the first.
* **Root cause class.** This is a **user-error class**, not a code
  bug. `SECOND_ROOT` is literally a descendant directory of
  `FIRST_ROOT` (the user picked something like
  `~/Pictures/tour` as FIRST_ROOT and `~/Pictures/tour/mountains` as
  SECOND_ROOT).
* **Distinguishing verify.** `cat directories.yaml | grep "^  - path:"`
  shows two entries; one path is a prefix of the other.
* **Resolution.** v1 does NOT collapse nested roots into a single
  hierarchy — each root walks independently and is rendered as a
  peer at the LazyVStack top level. If both roots appear as
  top-level peers regardless of containment, that is the contract.
  If the panel synthesizes a "merged tree," that is a regression in
  the projection (`walkerTreeView`, `buildView`) — file a separate
  bug because §2.4 explicitly requires peer rendering.

### 6.6 The "canonicalization mismatch" race

* **Symptom.** Immediately after §2's add, the file tree briefly
  shows two rows, then drops back to one. A second later it returns
  to two (or stays at one, depending on the race).
* **Root cause class.** This is the failure flagged in §2.2 step 9.
  `DirectoriesStore.addRoot` canonicalizes the path
  (`URL.standardizedFileURL` + `.resolvingSymlinksInPath()`), so the
  YAML stores the canonical form. `addDirectoryFromPicker` then
  calls `scheduleWalk(root: url, …)` with `url = panel.urls[i]`
  **before** canonicalization. The walker therefore keys the
  in-memory root by the raw `panel.urls[i]` URL.
  `reloadDirectoriesFromDisk`
  (`code/Sources/ImageGlass/AppState.swift:842`) then diffs the
  YAML's canonical paths against the walker's raw-URL keys. If they
  differ, the reconcile (a) schedules a *new* walk for the canonical
  URL and (b) removes the raw-URL entry. There is a window where
  `walkerRoots` has only the surviving entry (`FIRST_ROOT`).

* **Why it bites here specifically.** Most paths NSOpenPanel returns
  are byte-identical to their canonical form. But common
  edge cases that cause divergence are:

  * The user selected a folder reached through a symlink (e.g.
    `/Volumes/Drobo` is a symlink to `/Volumes/Drobo Pro`).
  * The user selected a folder whose path contains `//` or `.`
    components that `.standardizedFileURL` normalizes away.
  * Trailing-slash representation of the URL differs (NSOpenPanel
    occasionally returns a trailing slash for the *last* component
    of a multi-selection — see the AppKit changelog notes).
  * macOS firmlinks involving `/Users` (rare but possible after a
    user migrates from an external installer).

* **Distinguishing verify.**

  ```sh
  grep -E "tool=mcp.add_directory|app=directory.walk|app=directory.walk_start" \
      ~/Library/Application\ Support/ImageGlass_Mac/logs/log.log \
      | tail -n 12
  ```

  In a healthy run, after §2 you see **one** `tool=mcp.add_directory`
  for `SECOND_ROOT` and **one** `directory.walk_start` + **one**
  `directory.walk` pair for it. In the bug case you see **two**
  `directory.walk_start` lines for the *same* directory (one keyed by
  the raw URL, one by the canonical), and the `walkerRoots`
  snapshot at any single moment may contain either the raw or the
  canonical, but not both.

* **Fix shape.** `addDirectoryFromPicker` (and the two analogous
  helpers in `DirectoryFilenamePanel.swift:458` and
  `FloatingFileTreeWindow.swift:276`, plus the
  `addDirectoryFromPathPrompt` helper in
  `ImageGlassApp.swift:315`) should pass the **canonical** URL — the
  one returned from `DirectoriesStore.shared.addRoot` — to
  `scheduleWalk`, not the raw `panel.urls[i]` URL. The store already
  returns it as `(canonical: URL, alreadyExisted: Bool)`. Today the
  GUI ignores the `canonical` field and passes the raw `url`; that
  is the bug.

### 6.7 The "search filter eats the second root" failure

* **Symptom.** Both roots are in `walkerRoots`; the FIRST_ROOT
  expanded panel shows files; collapsing FIRST_ROOT shows nothing
  for SECOND_ROOT — even though SECOND_ROOT has many media files.
* **Root cause class.** The header's search text matches files in
  FIRST_ROOT but not in SECOND_ROOT. `DesignTreeNode.hasVisibleDescendant`
  (line 132) returns `false` for the SECOND_ROOT `DesignTreeNode`
  because *no descendant filename matches the search text*. With
  `if hasVisibleDescendant` failing, the entire root row is hidden.
* **Distinguishing verify.** Clear the search field in the panel
  header (the `xmark.circle.fill` button at the right of the
  search field). The second root re-appears immediately.
* **Implication for the test harness.** A regression test must
  either explicitly clear the search field before evaluating §2.4,
  or make the test fixtures' filenames share a substring so any
  reasonable search text matches both.

### 6.8 The "panel is in List mode, not Tree mode" mis-read

* **Symptom.** The user reports "I can't find the second root."
  Investigation: the panel is in `List` mode, which is the flat
  union of every visible file (`DirectoryFilenamePanel.listView`,
  `code/Sources/ImageGlass/DirectoryFilenamePanel.swift:224`). There
  are no "root" rows in list mode — files are grouped by parent
  folder, not by registered root, so the user perceives the second
  root as "missing" because they're looking for a top-level row that
  doesn't exist in this view mode.
* **Distinguishing verify.** Look at the segmented `List | Tree`
  control at the top of the panel. If `List` is selected, this is
  the failure. Click `Tree`. The two roots appear as peers.
* **Implication.** This is a "wrong view" misunderstanding, not a
  code bug. The spec's §0 precondition explicitly says the panel
  must be in Tree mode before §2 begins.

---

## 7. End-to-End Acceptance

A run of this scenario passes when **all of**:

* §1 — one root is registered; one entry in `directories.yaml`; one
  top-level row in Tree mode; one
  `tool=mcp.add_directory` + one `app=directory.walk` line in
  `log.log`.
* §2.3 — `directories.yaml` has exactly two entries in
  `root_directories[]`, in append order (FIRST_ROOT first,
  SECOND_ROOT second).
* §2.4 — the file panel in Tree mode shows exactly two top-level
  expandable rows, both expanded by default, as peers in the same
  `LazyVStack` with no indentation difference between them.
* §2.5 — after collapsing the first row, the second row remains
  visible as a peer (this is the user-reported failure mode; this
  is the **hero check**).
* §2.5 — the on-disk YAML, the walker snapshot, and the rendered
  tree all show count == 2 simultaneously.
* §3 — adding the same `SECOND_ROOT` a second time is a no-op on
  both disk and screen.
* §4 — collapsing one root does not affect the expansion state of
  the other root.
* The viewer canvas was **not** disturbed by the add. Whatever
  image was visible before §2 began is still visible after §2.5.
* `logs/log.log` contains four lines from §1 + §2 with shared
  `corr=` ids — two `tool=mcp.add_directory` and two
  `app=directory.walk` (one pair per root).

If the hero check (§2.5) fails, work down §6 in order until the
matching failure mode is identified. The most likely root cause
based on the implementation surveyed in §5 is **§6.6 — the
canonicalization mismatch race**, because that is the only race
that can produce the exact symptom "the second root briefly appears
and then is silently removed by the reconcile pass."
