import AppKit
import SwiftUI
import ImageGlassCore

/// Detached floating window that hosts the file list + file tree on a
/// bright-yellow background. Spec: `docs/list_of_files.mdx` §3C.
///
/// Owned as a single shared instance so toggling the View menu item
/// (⌃⌥⌘F) reuses the same window rather than spawning a new one. The
/// window opens automatically once per launch from
/// `AboutAppDelegate.applicationDidFinishLaunching` (§3C.1 default-on).
@MainActor
final class FloatingFileTreeWindowController {
    static let shared = FloatingFileTreeWindowController()

    private var window: NSWindow?

    private init() {}

    /// `true` when the floating window exists *and* is on screen. Used by
    /// the View menu so the item text flips between *Show* and *Hide*.
    var isVisible: Bool { window?.isVisible == true }

    /// Create-or-foreground. Idempotent: a second call with the window
    /// already on screen just brings it to the front.
    func show(state: AppState) {
        // docs/performance.mdx §5.4 / §10.12 — `Window.FloatingFileTree.Show`.
        let _trace = PerformanceLog.shared.start("Window.FloatingFileTree.Show")
        defer { _trace.finish() }
        if let existing = window {
            Self.placeOnMainWindowScreen(existing)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: FileTreeFloatingView(state: state))
        let win = NSWindow(contentViewController: hosting)
        win.title = "File Tree"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 360, height: 600))
        win.minSize = NSSize(width: 240, height: 320)
        win.isReleasedWhenClosed = false
        // Restorable=false: a closed-by-user window must re-open on the
        // next cold launch (§3C.1 default-on contract).
        win.isRestorable = false
        // NOTE: deliberately not calling setFrameAutosaveName. On
        // multi-monitor setups a saved frame can land the window on a
        // screen that's no longer attached (or where the main viewer
        // window isn't), which presents to the user as "the floating
        // window never appears." We re-place relative to the main
        // viewer window every show() instead.
        win.delegate = WindowDelegate.shared
        Self.placeOnMainWindowScreen(win)

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Move the floating window onto the screen the main viewer
    /// window currently lives on (or, if there isn't one yet, the
    /// screen under the cursor). Without this, plain `center()` lands
    /// the window on the primary screen — invisible when the main app
    /// is on a secondary monitor (e.g. main window x=7308 in the
    /// `window.resize` log).
    private static func placeOnMainWindowScreen(_ win: NSWindow) {
        let main = NSApp.windows.first { other in
            other !== win
                && other.canBecomeMain
                && other.styleMask.contains(.titled)
                && other.isVisible
        }
        let screen = main?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let target = screen else { win.center(); return }

        let visible = target.visibleFrame
        var f = win.frame
        // Park near the right edge of the main window's screen at the
        // vertical midpoint — out of the way of the viewer canvas but
        // still visible, regardless of how large the main window is.
        f.origin.x = visible.maxX - f.width - 24
        f.origin.y = visible.midY - f.height / 2
        win.setFrame(f, display: true)
    }

    /// Hide without releasing — keeps the cached `NSWindow` so the next
    /// `show()` brings the same frame back instantly.
    func hide() {
        // docs/performance.mdx §5.4 / §10.12 — `Window.FloatingFileTree.Hide`.
        let _trace = PerformanceLog.shared.start("Window.FloatingFileTree.Hide")
        defer { _trace.finish() }
        window?.orderOut(nil)
    }

    /// One-call entry point for the View menu item.
    func toggle(state: AppState) {
        if isVisible { hide() } else { show(state: state) }
    }

    fileprivate func windowDidClose() {
        // Per §3C.5 isReleasedWhenClosed=false, the NSWindow stays alive
        // after the user clicks the red traffic light. We just drop the
        // visibility so the View menu item flips back to "Show".
        // `window` itself is retained so a subsequent `show()` is fast.
    }

    @MainActor
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        static let shared = WindowDelegate()
        func windowWillClose(_ notification: Notification) {
            FloatingFileTreeWindowController.shared.windowDidClose()
        }
    }
}

/// Content view rendered inside the floating window. Splits the content
/// rect vertically: file list on top, file tree on bottom. Every row
/// sits on the bright-yellow background.
///
/// Selection in either half writes through to `state.selectedFile`,
/// which the main viewer canvas observes — clicking a row here loads
/// the image in the main window. Matches the inline panel's behavior
/// (`DirectoryFilenamePanel`) so the two surfaces stay in sync.
struct FileTreeFloatingView: View {

    @Bindable var state: AppState

    /// Bright-yellow only for the *detached* floating window (spec §3C.3).
    /// When embedded inline in the main window's left column this is `false`,
    /// so the panel uses the design's neutral sidebar material instead.
    var useYellowBackground: Bool = false

    /// `#FFFF00` — the spec's bright yellow (§3C.3). Applied as a
    /// `.background` so it composes correctly with the SwiftUI `List`
    /// row chrome.
    private static let brightYellow = Color(red: 1.0, green: 1.0, blue: 0.0)

    /// Panel/list fill: yellow for the floating window, neutral sidebar inline.
    private var panelBackground: Color { useYellowBackground ? Self.brightYellow : IG.sidebarC }
    /// Row fill: yellow for the floating window, clear inline (so List
    /// selection highlight shows through).
    private var rowBackground: Color { useYellowBackground ? Self.brightYellow : Color.clear }

    var body: some View {
        VStack(spacing: 0) {
            if storedRootCount == 0 && state.resolvedFiles.isEmpty {
                // §3C.7 empty state — same shape as the inline panel.
                emptyState
            } else {
                VSplitView {
                    listSection
                        .frame(minHeight: 80)
                    treeSection
                        .frame(minHeight: 80)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelBackground)
    }

    // MARK: - List half (top)

    private var listSection: some View {
        let files: [String] = state.walkerRoots.isEmpty
            ? state.resolvedFiles
            : DirectoryFilenamePanel.flattenVisible(state.walkerRoots)
        // Explicit `.onTapGesture` for the same reason described in
        // `SelectableTreeRenderer.row` — `List(selection:)` alone does
        // not reliably fire single-click selection from a non-key
        // floating window. The tap mutates `state.selectedFile`
        // directly so the main viewer loads on first click.
        return List(selection: $state.selectedFile) {
            ForEach(files, id: \.self) { path in
                HStack(spacing: 6) {
                    Image(systemName: iconForPath(path))
                        .foregroundStyle(.secondary)
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .listRowBackground(rowBackground)
                .tag(path as String?)
                .onTapGesture { state.selectedFile = path }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(panelBackground)
    }

    // MARK: - Tree half (bottom)

    @ViewBuilder
    private var treeSection: some View {
        if state.walkerRoots.isEmpty {
            legacyTreeSection
        } else {
            walkerTreeSection
        }
    }

    private var walkerTreeSection: some View {
        // docs/list_of_files.mdx §3D.5 — the floating window picks the
        // same renderer the inline panel does (View ▸ Tree View
        // submenu). `useYellowBackground=true` keeps §3C.3's bright-
        // yellow contract through the renderer swap.
        SelectableTreeRenderer(state: state, useYellowBackground: useYellowBackground)
    }

    private var legacyTreeSection: some View {
        let roots = FileTreeNode.build(from: state.resolvedFiles)
        return List(selection: $state.selectedFile) {
            ForEach(roots) { root in
                OutlineGroup(root, children: \.children) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.isDirectory
                              ? "folder"
                              : iconForPath(node.fullPath ?? node.name))
                            .foregroundStyle(node.isDirectory ? .blue : .secondary)
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .listRowBackground(rowBackground)
                    .tag(node.fullPath ?? "" as String?)
                    .onTapGesture {
                        if let path = node.fullPath, !node.isDirectory {
                            state.selectedFile = path
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(panelBackground)
    }

    private func rootHeader(_ root: RootDirectory) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
            Text(root.path.path)
                .lineLimit(1)
                .truncationMode(.head)
                .font(.system(.caption, design: .monospaced))
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No directories added")
                .foregroundStyle(.secondary)
            Button("+ Add directory") {
                addDirectoryFromPicker()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Opens `NSOpenPanel` (folder picker). Each picked folder becomes
    /// a new root in `directories.yaml` and triggers a walk via
    /// `DirectoryTreeWalker.shared.scheduleWalk`. Same code path as the
    /// Directories menu's "Add Directory…" item.
    private func addDirectoryFromPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let corr = MCPAuditLogger.newCorrelationId()
            do {
                let (canonical, already) = try DirectoriesStore.shared.addRoot(path: url.path)
                if !already {
                    MCPAuditLogger.shared.logDirectoryToolCall(
                        toolName: "add_directory",
                        path: canonical.path,
                        client: "gui",
                        corr: corr,
                        ok: true
                    )
                    // Walker key must equal the canonical YAML path — see
                    // docs/use_cases/add_dir_of_images.md §6.6.
                    DirectoryTreeWalker.shared.scheduleWalk(
                        root: canonical,
                        filter: .empty,
                        corr: corr
                    )
                }
            } catch {
                MCPAuditLogger.shared.logDirectoryToolCall(
                    toolName: "add_directory",
                    path: url.path,
                    client: "gui",
                    corr: corr,
                    ok: false,
                    err: "path_not_found"
                )
            }
        }
    }

    // MARK: - Helpers

    private var storedRootCount: Int {
        if !state.walkerRoots.isEmpty { return state.walkerRoots.count }
        return (try? DirectoriesStore.shared.load().roots.count) ?? 0
    }

    private func iconForPath(_ path: String) -> String {
        if let kind = FileKind.classify(path: path) {
            return iconForKind(kind)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "psd", "ai": return "paintbrush"
        default:          return "doc"
        }
    }

    private func iconForKind(_ kind: FileKind?) -> String {
        switch kind {
        case .image: return "photo"
        case .svg:   return "vector.path"
        case .video: return "film"
        case nil:    return "doc"
        }
    }
}
