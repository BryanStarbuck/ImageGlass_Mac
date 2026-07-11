@preconcurrency import AppKit
import Foundation
import ImageGlassCore
import QuickLookUI
import UniformTypeIdentifiers

/// docs/right_click.mdx §9.4 — the per-item handlers used by every
/// surface's menu builder. Each handler emits a single
/// `tool=menu.click` audit line on a fresh correlation id, then
/// dispatches to the canonical verb (`FileActions.*`,
/// `IncludeStateController.*`, `DirectoriesStore.*`, `viewer.*`, …).
/// The dispatched verb emits its own audit line on the same `corr=`,
/// so a debugger can pair the click with the resulting state change.
///
/// Every handler is `@MainActor` because it touches AppKit
/// (NSPasteboard, NSWorkspace, NSOpenPanel, QLPreviewPanel) and the
/// SwiftUI `AppState` observable graph.
@MainActor
enum ContextMenuActions {

    /// Stable kebab-case ids for telemetry (right_click.mdx §9.4) and
    /// for XCUITest `accessibilityIdentifier` lookups (§9.5).
    enum ItemID: String {
        case open
        case openInNewWindow = "open-in-new-window"
        case openInFloatingViewer = "open-in-floating-viewer"
        case openWith = "open-with"
        case quickLook = "quick-look"
        case revealInFinder = "reveal-in-finder"
        case openInTerminal = "open-in-terminal"
        case copyImage = "copy-image"
        case copyFilePath = "copy-file-path"
        case copyFolderPath = "copy-folder-path"
        case include
        case inherit
        case dontInclude = "dont-include"
        case includeChildren = "include-including-children"
        case dontIncludeChildren = "dont-include-including-children"
        case changeInclude = "change-include"
        case changeIncludeOn = "change-include.on"
        case changeIncludeOff = "change-include.off"
        case showInFileList = "show-in-file-list"
        case showInTreeView = "show-in-tree-view"
        case showMetadata = "show-metadata"
        case setAsDesktopPicture = "set-as-desktop-picture"
        case rename
        case moveToTrash = "move-to-trash"
        case moveFolderToTrash = "move-folder-to-trash"
        case addDirectory = "add-directory"
        case addDirectoryFromClipboard = "add-directory-from-clipboard"
        case removeDirectory = "remove-directory"
        case refreshThisRoot = "refresh-this-root"
        case refreshAllRoots = "refresh-all-roots"
        case reevaluateScope = "reevaluate-scope"
        case revealLocalStorage = "reveal-local-storage"
        case clearAllDirectories = "clear-all-directories"
        case editFilter = "edit-filter"
        case clearFilter = "clear-filter"
        case moveRootUp = "move-root-up"
        case moveRootDown = "move-root-down"
        case moveRootToTop = "move-root-to-top"
        case moveRootToBottom = "move-root-to-bottom"
        case addSubfolderAsRoot = "add-subfolder-as-root"
        case removeFolderFromScope = "remove-folder-from-scope"
        case expandSubtree = "expand-subtree"
        case collapseSubtree = "collapse-subtree"
        case switchViewTree = "switch-view.tree"
        case switchViewList = "switch-view.list"
        case sortByName = "sort-by.name"
        case sortByDateModified = "sort-by.date-modified"
        case sortByDateCreated = "sort-by.date-created"
        case sortBySize = "sort-by.size"
        case sortByKind = "sort-by.kind"
        case sortAscending = "sort-by.ascending"
        case sortDescending = "sort-by.descending"
        case zoomToFit = "zoom-to-fit"
        case zoomToWidth = "zoom-to-width"
        case zoomActual = "zoom-actual"
        case lockZoom = "lock-zoom"
        case rotateLeft = "rotate-left"
        case rotateRight = "rotate-right"
        case flipHorizontal = "flip-horizontal"
        case flipVertical = "flip-vertical"
        case colorPicker = "color-picker"
        case showChannelsAll = "show-channels.all"
        case showChannelsRed = "show-channels.red"
        case showChannelsGreen = "show-channels.green"
        case showChannelsBlue = "show-channels.blue"
        case showChannelsAlpha = "show-channels.alpha"
        case showChannelsLuminance = "show-channels.luminance"
        case nextImage = "next-image"
        case previousImage = "previous-image"
        case saveAs = "save-as"
        case convertToPNG = "convert-to.png"
        case convertToJPEG = "convert-to.jpeg"
        case convertToHEIC = "convert-to.heic"
        case convertToTIFF = "convert-to.tiff"
        case convertToWebP = "convert-to.webp"
        case convertToAVIF = "convert-to.avif"
        case convertToJXL = "convert-to.jxl"
        case print
        case hidePanel = "hide-panel"
        case copyStatusText = "copy-status-text"
        case openWithOther = "open-with.other"
        case openWithAppStore = "open-with.app-store"
    }

    /// Stable kebab-case ids for the surface a menu belongs to
    /// (right_click.mdx §9.4 / §12).
    enum SurfaceID: String {
        case fileRow = "directory_panel.file_row"
        case folderRow = "directory_panel.folder_row"
        case rootRow = "directory_panel.root_row"
        case panelEmpty = "directory_panel.empty"
        case panelHeader = "directory_panel.header"
        case fileListItem = "file_list.item"
        case viewerCanvas = "viewer.canvas"
        case viewerVideo = "viewer.video"
        case viewerSVG = "viewer.svg"
        case imageInfoOverlay = "viewer.image_info_overlay"
        case galleryStrip = "gallery.strip"
        case floatingFileTree = "window.floating_file_tree"
        case panelHeaderTab = "panel.header_tab"
        case statusBar = "status_bar"
    }

    // MARK: - Click recorder

    /// Emit the §9.4 `tool=menu.click` line and return the correlation
    /// id so the dispatched verb can attach its own line on the same id.
    @discardableResult
    static func recordClick(menu: SurfaceID, item: ItemID,
                            extra: [(String, String)] = []) -> String {
        let corr = MCPAuditLogger.newCorrelationId()
        var pairs: [(String, String)] = [
            ("tool", "menu.click"),
            ("menu", menu.rawValue),
            ("item", item.rawValue),
        ]
        pairs.append(contentsOf: extra)
        pairs.append(("source", "menu:context"))
        pairs.append(("corr", corr))
        pairs.append(("ok", "true"))
        MCPAuditLogger.shared.log(pairs)
        return corr
    }

    /// Emit the §12 `tool=menu.open` line. Called by `ContextMenuBridge`
    /// right before `NSMenu.popUp(positioning:at:in:)`.
    static func recordOpen(menu: SurfaceID, itemCount: Int,
                           targetPath: String?, selectedCount: Int = 1) {
        var pairs: [(String, String)] = [
            ("tool", "menu.open"),
            ("menu", menu.rawValue),
        ]
        if let targetPath { pairs.append(("path", targetPath)) }
        pairs.append(("items", String(itemCount)))
        pairs.append(("selected", String(selectedCount)))
        pairs.append(("source", "event:right-click"))
        pairs.append(("corr", MCPAuditLogger.newCorrelationId()))
        pairs.append(("ok", "true"))
        MCPAuditLogger.shared.log(pairs)
    }

    // MARK: - File-row verbs

    static func open(state: AppState, path: String) {
        _ = recordClick(menu: .fileRow, item: .open)
        state.selectedFile = path
    }

    static func openInNewWindow(state: AppState, path: String) {
        _ = recordClick(menu: .fileRow, item: .openInNewWindow)
        // actions.mdx §7 / right_click.mdx §7.1 item 2 — New Window is
        // spawned through `ImageGlassWindowActions.openNewImageWindow`,
        // which needs `@Environment(\.openWindow)`. That env value is
        // only reachable from inside a SwiftUI `View`, so we hop through
        // a notification observed by the WindowGroup root. The pre-
        // selected file path is staged in `PendingNewWindowSelection`
        // and consumed by the new window's bootstrap (see
        // `WindowStateController` initial selection plumbing).
        PendingNewWindowSelection.shared.path = path
        NotificationCenter.default.post(name: .imageGlassOpenNewWindow,
                                        object: nil)
    }

    static func openInFloatingViewer(state: AppState, path: String) {
        _ = recordClick(menu: .fileRow, item: .openInFloatingViewer)
        // The Second Viewer mirrors the active selection; switch the
        // selection then show the window so the secondary viewer paints
        // the right image.
        state.selectedFile = path
        SecondViewerWindowController.shared.show(state: state)
    }

    static func quickLook(state: AppState, path: String) {
        _ = recordClick(menu: .fileRow, item: .quickLook)
        QuickLookCoordinator.shared.preview(url: URL(fileURLWithPath: path))
    }

    static func revealInFinder(menu: SurfaceID, path: String) {
        _ = recordClick(menu: menu, item: .revealInFinder)
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
           isDir.boolValue {
            // Folder: open the folder window itself, no selection.
            NSWorkspace.shared.selectFile(nil,
                                          inFileViewerRootedAtPath: url.path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func openInTerminal(menu: SurfaceID, path: String) {
        _ = recordClick(menu: menu, item: .openInTerminal)
        let url = URL(fileURLWithPath: path)
        let workspace = NSWorkspace.shared
        if let term = workspace.urlForApplication(withBundleIdentifier:
                                                  "com.apple.Terminal") {
            let cfg = NSWorkspace.OpenConfiguration()
            workspace.open([url], withApplicationAt: term,
                           configuration: cfg, completionHandler: nil)
        }
    }

    static func copyImage(state: AppState, menu: SurfaceID) {
        _ = recordClick(menu: menu, item: .copyImage)
        FileActions.copyImageToClipboard(state: state, source: .context)
    }

    static func copyFilePath(state: AppState, menu: SurfaceID) {
        _ = recordClick(menu: menu, item: .copyFilePath)
        FileActions.copyFilePath(state: state, source: .context)
    }

    static func copyFolderPath(menu: SurfaceID, path: String) {
        _ = recordClick(menu: menu, item: .copyFolderPath)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path, forType: .string)
    }

    static func showInFileList(state: AppState, path: String) {
        _ = recordClick(menu: .fileRow, item: .showInFileList)
        state.panelViewMode = .list
        state.selectedFile = path
    }

    static func showInTreeView(state: AppState, path: String) {
        _ = recordClick(menu: .fileListItem, item: .showInTreeView)
        state.panelViewMode = .tree
        state.selectedFile = path
    }

    static func setAsDesktopPicture(menu: SurfaceID, path: String) {
        _ = recordClick(menu: menu, item: .setAsDesktopPicture)
        guard let screen = NSScreen.main else { return }
        let url = URL(fileURLWithPath: path)
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
    }

    static func rename(state: AppState, menu: SurfaceID) {
        _ = recordClick(menu: menu, item: .rename)
        FileActions.renameViaSheet(state: state, source: .context)
    }

    static func moveToTrash(state: AppState, menu: SurfaceID) {
        _ = recordClick(menu: menu, item: .moveToTrash)
        FileActions.moveToTrash(state: state, source: .context)
    }

    static func moveFolderToTrash(menu: SurfaceID, path: String) {
        _ = recordClick(menu: menu, item: .moveFolderToTrash, extra: [("path", path)])
        let url = URL(fileURLWithPath: path)
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "You can put it back later from the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var resulting: NSURL? = nil
        try? FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }

    // MARK: - Folder-row verbs

    static func expandSubtree(state: AppState, folderPath: String) {
        _ = recordClick(menu: .folderRow, item: .expandSubtree)
        // Open this node and walk every visible descendant directory.
        state.treeNav.setExpanded(folderPath, true)
        for root in state.walkerRoots {
            if folderPath == root.path.path
                || folderPath.hasPrefix(root.path.path + "/"),
               let tree = root.tree {
                expandAllUnder(node: tree, parentPath: root.path,
                               match: folderPath, into: state.treeNav)
                break
            }
        }
    }

    private static func expandAllUnder(node: DirectoryNode, parentPath: URL,
                                       match: String, into nav: TreeNavigator) {
        switch node {
        case .file:
            return
        case .directory(_, let children):
            let path = parentPath.path
            if path == match || path.hasPrefix(match + "/") {
                nav.setExpanded(path, true)
            }
            for child in children {
                let childURL = parentPath.appendingPathComponent(child.name)
                expandAllUnder(node: child, parentPath: childURL,
                               match: match, into: nav)
            }
        }
    }

    static func collapseSubtree(state: AppState, folderPath: String) {
        _ = recordClick(menu: .folderRow, item: .collapseSubtree)
        state.treeNav.setExpanded(folderPath, false)
        for p in Array(state.treeNav.explicitlyExpanded) {
            if p.hasPrefix(folderPath + "/") {
                state.treeNav.setExpanded(p, false)
            }
        }
    }

    static func addSubfolderAsRoot(state: AppState, folderPath: String) {
        _ = recordClick(menu: .folderRow, item: .addSubfolderAsRoot,
                        extra: [("path", folderPath)])
        let corr = MCPAuditLogger.newCorrelationId()
        do {
            let (canonical, already) = try DirectoriesStore.shared.addRoot(path: folderPath)
            if !already {
                MCPAuditLogger.shared.logDirectoryToolCall(
                    toolName: "add_directory", path: canonical.path,
                    client: "gui", corr: corr, ok: true
                )
                DirectoryTreeWalker.shared.scheduleWalk(
                    root: canonical, filter: .empty, corr: corr
                )
            }
        } catch {
            MCPAuditLogger.shared.logDirectoryToolCall(
                toolName: "add_directory", path: folderPath,
                client: "gui", corr: corr, ok: false, err: "path_not_found"
            )
        }
    }

    // MARK: - Root-row verbs

    static func refreshThisRoot(state: AppState, rootPath: URL) {
        _ = recordClick(menu: .rootRow, item: .refreshThisRoot,
                        extra: [("path", rootPath.path)])
        let corr = MCPAuditLogger.newCorrelationId()
        // Find the current filter for this root so the refresh re-walks
        // with the same constraints the user already set.
        let file = (try? DirectoriesStore.shared.load()) ?? DirectoriesFile()
        let filter = file.roots.first(where: { $0.path == rootPath })?.filter ?? .empty
        MCPAuditLogger.shared.logDirectoryToolCall(
            toolName: "refresh_directory", path: rootPath.path,
            client: "gui", corr: corr, ok: true
        )
        DirectoryTreeWalker.shared.scheduleWalk(root: rootPath,
                                                filter: filter, corr: corr)
    }

    static func refreshAllRoots(state: AppState, menu: SurfaceID) {
        _ = recordClick(menu: menu, item: .refreshAllRoots)
        let file = (try? DirectoriesStore.shared.load()) ?? DirectoriesFile()
        let corr = MCPAuditLogger.newCorrelationId()
        MCPAuditLogger.shared.logDirectoryToolCall(
            toolName: "refresh_directory", path: nil,
            client: "gui", corr: corr, ok: true,
            extra: [("roots", String(file.roots.count))]
        )
        for r in file.roots {
            DirectoryTreeWalker.shared.scheduleWalk(
                root: r.path, filter: r.filter, corr: corr
            )
        }
    }

    static func removeDirectory(state: AppState, rootPath: URL) {
        _ = recordClick(menu: .rootRow, item: .removeDirectory,
                        extra: [("path", rootPath.path)])
        let corr = MCPAuditLogger.newCorrelationId()
        do {
            let removed = try DirectoriesStore.shared.removeRoot(path: rootPath.path)
            MCPAuditLogger.shared.logDirectoryToolCall(
                toolName: "remove_directory", path: rootPath.path,
                client: "gui", corr: corr, ok: removed
            )
            if removed {
                DirectoryTreeWalker.shared.removeRoot(path: rootPath)
                state.refreshWalkerRoots()
                MCPNotificationBus.shared.postDirectoriesChanged()
            }
        } catch {
            MCPAuditLogger.shared.logDirectoryToolCall(
                toolName: "remove_directory", path: rootPath.path,
                client: "gui", corr: corr, ok: false, err: "unknown"
            )
        }
    }

    static func moveRoot(state: AppState, rootPath: URL,
                         direction: RootMoveDirection) {
        let itemID: ItemID = switch direction {
            case .up:       .moveRootUp
            case .down:     .moveRootDown
            case .top:      .moveRootToTop
            case .bottom:   .moveRootToBottom
        }
        _ = recordClick(menu: .rootRow, item: itemID,
                        extra: [("path", rootPath.path)])
        var file = (try? DirectoriesStore.shared.load()) ?? DirectoriesFile()
        guard let idx = file.roots.firstIndex(where: { $0.path == rootPath }) else { return }
        let entry = file.roots.remove(at: idx)
        let newIdx: Int = switch direction {
            case .up:       max(0, idx - 1)
            case .down:     min(file.roots.count, idx + 1)
            case .top:      0
            case .bottom:   file.roots.count
        }
        file.roots.insert(entry, at: newIdx)
        try? DirectoriesStore.shared.save(file)
        state.refreshWalkerRoots()
        MCPNotificationBus.shared.postDirectoriesChanged()
    }

    enum RootMoveDirection { case up, down, top, bottom }

    static func clearFilterOnRoot(state: AppState, rootPath: URL) {
        _ = recordClick(menu: .rootRow, item: .clearFilter,
                        extra: [("path", rootPath.path)])
        _ = try? DirectoriesStore.shared.updateFilter(path: rootPath.path,
                                                      filter: .empty)
        state.refreshWalkerRoots()
        MCPNotificationBus.shared.postDirectoriesChanged()
    }

    // MARK: - Include-state verbs

    static func setIncludeState(state: AppState, path: String,
                                target: IncludeState,
                                menu: SurfaceID) {
        let itemID: ItemID = switch target {
            case .include:  .include
            case .inherit:  .inherit
            case .exclude:  .dontInclude
        }
        _ = recordClick(menu: menu, item: itemID, extra: [("path", path)])
        _ = IncludeStateController.setState(absolutePath: path,
                                            state: target,
                                            appState: state)
    }

    /// include_checks.mdx §7.2 — "Include On / Off (including children)".
    /// Recursively set `path` and every descendant to `target`
    /// (right_click.mdx §7.1 item / §7.2). `target` is `.include` or
    /// `.exclude`; `.inherit` is not offered for the recursive verb.
    static func setIncludeStateRecursive(state: AppState, path: String,
                                         target: IncludeState,
                                         menu: SurfaceID) {
        let itemID: ItemID = target == .include
            ? .includeChildren : .dontIncludeChildren
        _ = recordClick(menu: menu, item: itemID,
                        extra: [("path", path), ("recursive", "true")])
        _ = IncludeStateController.setSubtree(absolutePath: path,
                                              state: target,
                                              appState: state)
    }

    /// include_checks.mdx §7.3 — "Change Include ▸ Change Include On /
    /// Off". Switch the entire tree (all roots + all nodes) to `target`
    /// (right_click.mdx §7.2). Default is off; "Change Include On" sets
    /// every row to `.include`, "Change Include Off" to `.exclude`.
    static func changeIncludeWholeTree(state: AppState,
                                       target: IncludeState,
                                       menu: SurfaceID, path: String) {
        let itemID: ItemID = target == .include
            ? .changeIncludeOn : .changeIncludeOff
        _ = recordClick(menu: menu, item: itemID,
                        extra: [("path", path), ("scope", "entire_tree")])
        _ = IncludeStateController.setEntireTree(state: target,
                                                 appState: state)
    }

    // MARK: - Panel-empty / panel-header verbs

    static func addDirectoryFromPicker(state: AppState) {
        _ = recordClick(menu: .panelEmpty, item: .addDirectory)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let corr = MCPAuditLogger.newCorrelationId()
            do {
                let (canonical, already) = try DirectoriesStore.shared
                    .addRoot(path: url.path)
                if !already {
                    MCPAuditLogger.shared.logDirectoryToolCall(
                        toolName: "add_directory", path: canonical.path,
                        client: "gui", corr: corr, ok: true
                    )
                    DirectoryTreeWalker.shared.scheduleWalk(
                        root: canonical, filter: .empty, corr: corr
                    )
                }
            } catch {
                MCPAuditLogger.shared.logDirectoryToolCall(
                    toolName: "add_directory", path: url.path,
                    client: "gui", corr: corr, ok: false, err: "path_not_found"
                )
            }
        }
    }

    static func addDirectoryFromClipboard(state: AppState) {
        _ = recordClick(menu: .panelEmpty, item: .addDirectoryFromClipboard)
        guard let candidate = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = AppPaths.expandTilde(trimmed)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else { return }
        let corr = MCPAuditLogger.newCorrelationId()
        do {
            let (canonical, _) = try DirectoriesStore.shared.addRoot(path: expanded)
            MCPAuditLogger.shared.logDirectoryToolCall(
                toolName: "add_directory", path: canonical.path,
                client: "gui", corr: corr, ok: true
            )
            DirectoryTreeWalker.shared.scheduleWalk(
                root: canonical, filter: .empty, corr: corr
            )
        } catch {
            MCPAuditLogger.shared.logDirectoryToolCall(
                toolName: "add_directory", path: expanded,
                client: "gui", corr: corr, ok: false, err: "path_not_found"
            )
        }
    }

    static func reevaluateScope(state: AppState, menu: SurfaceID) {
        _ = recordClick(menu: menu, item: .reevaluateScope)
        Task { await state.reevaluateActive() }
    }

    static func revealLocalStorage(menu: SurfaceID) {
        _ = recordClick(menu: menu, item: .revealLocalStorage)
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.macDirectoriesFile])
    }

    static func clearAllDirectories(state: AppState) {
        _ = recordClick(menu: .panelEmpty, item: .clearAllDirectories)
        let alert = NSAlert()
        alert.messageText = "Remove all directories from the scope?"
        alert.informativeText = "Files on disk are not affected. " +
            "You can add directories back later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? DirectoriesStore.shared.clearAll()
        state.refreshWalkerRoots()
        MCPNotificationBus.shared.postDirectoriesChanged()
    }

    // MARK: - View / sort

    static func setPanelView(state: AppState, mode: AppState.PanelViewMode) {
        let id: ItemID = (mode == .tree) ? .switchViewTree : .switchViewList
        _ = recordClick(menu: .panelEmpty, item: id)
        state.panelViewMode = mode
    }

    // MARK: - Image-canvas verbs

    static func canvasNextImage(state: AppState, viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .nextImage)
        advanceSelection(state: state, delta: +1)
    }

    static func canvasPreviousImage(state: AppState, viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .previousImage)
        advanceSelection(state: state, delta: -1)
    }

    /// Walk the resolved file list and pick the neighbor `delta` away
    /// from the current selection. Mirrors the right-arrow / left-arrow
    /// behavior the viewer hotkeys use.
    private static func advanceSelection(state: AppState, delta: Int) {
        let files: [String]
        if !state.walkerRoots.isEmpty {
            files = DirectoryFilenamePanel.flattenVisible(state.walkerRoots)
        } else {
            files = state.resolvedFiles
        }
        guard !files.isEmpty else { return }
        let current = state.selectedFile.flatMap { files.firstIndex(of: $0) }
        let next: Int = {
            guard let current else { return delta > 0 ? 0 : files.count - 1 }
            let raw = current + delta
            return max(0, min(files.count - 1, raw))
        }()
        state.selectedFile = files[next]
    }

    static func canvasZoomToFit(viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .zoomToFit)
        viewer.zoomToFit()
    }

    static func canvasZoomToWidth(viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .zoomToWidth)
        viewer.zoomToWidth()
    }

    static func canvasZoomActual(viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .zoomActual)
        viewer.zoomToActual()
    }

    static func canvasRotateLeft(viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .rotateLeft)
        viewer.rotateCounterClockwise()
    }

    static func canvasRotateRight(viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .rotateRight)
        viewer.rotateClockwise()
    }

    static func canvasFlipHorizontal(viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .flipHorizontal)
        viewer.toggleFlipHorizontal()
    }

    static func canvasFlipVertical(viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .flipVertical)
        viewer.toggleFlipVertical()
    }

    static func canvasToggleColorPicker(viewer: ViewerState) {
        _ = recordClick(menu: .viewerCanvas, item: .colorPicker)
        viewer.showColorPicker.toggle()
    }

    static func canvasShowInDirectoryPanel(state: AppState) {
        _ = recordClick(menu: .viewerCanvas, item: .showInFileList)
        guard let path = state.selectedFile else { return }
        // The tree's existing reveal hook ensures every ancestor folder
        // opens and the row scrolls into view.
        state.treeNav.revealAncestors(of: path)
        state.treeNav.activeRow = path
    }

    // MARK: - Save / convert

    static func saveAs(state: AppState) {
        _ = recordClick(menu: .viewerCanvas, item: .saveAs)
        guard let path = state.selectedFile else { return }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard let img = NSImage(contentsOf: url) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            let ext = dest.pathExtension.lowercased()
            let type: NSBitmapImageRep.FileType = switch ext {
                case "jpg", "jpeg": .jpeg
                case "tif", "tiff": .tiff
                case "gif":          .gif
                case "bmp":          .bmp
                default:             .png
            }
            if let data = rep.representation(using: type, properties: [:]) {
                try? data.write(to: dest)
            }
        }
    }

    static func convertTo(state: AppState, item: ItemID, ext: String,
                          bitmapType: NSBitmapImageRep.FileType) {
        _ = recordClick(menu: .viewerCanvas, item: item)
        guard let path = state.selectedFile else { return }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard let img = NSImage(contentsOf: url),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension()
            .appendingPathExtension(ext).lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if let data = rep.representation(using: bitmapType, properties: [:]) {
            try? data.write(to: dest)
        }
    }

    static func print(state: AppState) {
        _ = recordClick(menu: .viewerCanvas, item: .print)
        FileActions.printImage(state: state, source: .context)
    }

    // MARK: - Open With dispatch

    /// Open the file using a specific app URL.
    static func openWith(state: AppState, path: String, appURL: URL,
                        menu: SurfaceID, identifier: String) {
        _ = recordClick(menu: menu,
                        item: .openWith,
                        extra: [("with", identifier), ("path", path)])
        let url = URL(fileURLWithPath: path)
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: cfg, completionHandler: nil)
    }

    /// Open the file using the system default app for its UTI.
    static func openWithDefault(state: AppState, path: String,
                                menu: SurfaceID) {
        _ = recordClick(menu: menu, item: .openWith,
                        extra: [("with", "default"), ("path", path)])
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Show the system "choose app" `NSOpenPanel` scoped to the
    /// `.applicationBundle` UTI.
    static func openWithOther(state: AppState, path: String,
                              menu: SurfaceID) {
        _ = recordClick(menu: menu, item: .openWithOther,
                        extra: [("path", path)])
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: appURL,
                                configuration: cfg, completionHandler: nil)
    }

    static func copyStatusText(text: String) {
        _ = recordClick(menu: .statusBar, item: .copyStatusText)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Quick Look coordinator

/// Thin singleton wrapper around `QLPreviewPanel` because the panel
/// is a true `NSResponder`-based singleton and needs a data-source
/// object that outlives the calling menu handler.
@MainActor
final class QuickLookCoordinator: NSObject {
    static let shared = QuickLookCoordinator()
    private var items: [QLPreviewItem] = []

    func preview(url: URL) {
        items = [url as NSURL]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
}

extension QuickLookCoordinator: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!,
                      previewItemAt index: Int) -> QLPreviewItem! {
        items[index]
    }
}
