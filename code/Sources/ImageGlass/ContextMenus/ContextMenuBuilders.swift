@preconcurrency import AppKit
import Foundation
import ImageGlassCore
import SwiftUI
import UniformTypeIdentifiers

/// docs/right_click.mdx §9.1 — the single canonical builder file. Every
/// context-menu surface in the app routes through one of these factory
/// methods so item text, order, separators, ellipses, and shortcut
/// display cannot drift between surfaces.
///
/// AppKit-hosted surfaces (panel rows, panel empty space, image canvas)
/// receive an `NSMenu` here. SwiftUI-hosted surfaces (Grid / Strip /
/// Details / Column file-list cells) embed the returned `View` inside
/// their own `.contextMenu { }` modifier.
@MainActor
enum ContextMenuBuilders {

    // MARK: - Shortcut display helpers

    /// Build a key-equivalent + modifier-mask pair for the right-aligned
    /// shortcut shown next to a menu item. Use `nil` for the equivalent
    /// when the item has no shortcut twin.
    private struct Shortcut {
        let key: String
        let mods: NSEvent.ModifierFlags

        static let cmdC      = Shortcut(key: "c", mods: [.command])
        static let ctrlCmdC  = Shortcut(key: "c", mods: [.command, .control])
        static let cmdN      = Shortcut(key: "n", mods: [.command])
        static let cmdR      = Shortcut(key: "r", mods: [.command])
        static let cmdP      = Shortcut(key: "p", mods: [.command])
        static let shiftCmdS = Shortcut(key: "s", mods: [.command, .shift])
        static let cmdL      = Shortcut(key: "l", mods: [.command])
        static let cmdD      = Shortcut(key: "d", mods: [.command])
        static let optCmdG   = Shortcut(key: "g", mods: [.command, .option])
        static let cmdK      = Shortcut(key: "k", mods: [.command])
        static let optCmdH   = Shortcut(key: "h", mods: [.command, .option])
        static let optCmdV   = Shortcut(key: "v", mods: [.command, .option])
        static let optCmdI   = Shortcut(key: "i", mods: [.command, .option])
        static let shiftCmdK = Shortcut(key: "k", mods: [.command, .shift])
        static let cmdDelete = Shortcut(key: "\u{8}", mods: [.command])  // ⌘⌫
        static let shiftCmdDelete = Shortcut(key: "\u{8}", mods: [.command, .shift])
        static let ctrlCmdF  = Shortcut(key: "f", mods: [.command, .control, .option])
        static let ctrl1     = Shortcut(key: "1", mods: [.control])
        static let ctrl2     = Shortcut(key: "2", mods: [.control])
        static let ctrl3     = Shortcut(key: "3", mods: [.control])
        static let optArrowR = Shortcut(key: "\u{1D}", mods: [.option])
        static let optArrowL = Shortcut(key: "\u{1C}", mods: [.option])
        static let arrowR    = Shortcut(key: "\u{1D}", mods: [])
        static let arrowL    = Shortcut(key: "\u{1C}", mods: [])
        static let space     = Shortcut(key: " ", mods: [])
        static let f2        = Shortcut(key: String(format: "%c", 0xF705), mods: [])
        static let shiftF10  = Shortcut(key: String(format: "%c", 0xF70D), mods: [.shift])
        static let returnKey = Shortcut(key: "\u{D}", mods: [])
        static let nKey      = Shortcut(key: "n", mods: [])
        static let zKey      = Shortcut(key: "z", mods: [])
        static let wKey      = Shortcut(key: "w", mods: [])
        static let mKey      = Shortcut(key: "m", mods: [])
        static let ctrlCmdL  = Shortcut(key: "l", mods: [.command, .control])
    }

    /// Item factory wrapper that fills in `keyEquivalent`,
    /// `keyEquivalentModifierMask`, `target/action`, identifier, and
    /// tooltip in one place. Items returned here are ready to add to a
    /// menu.
    private static func item(_ title: String,
                             id: ContextMenuActions.ItemID,
                             shortcut: Shortcut? = nil,
                             tooltip: String? = nil,
                             enabled: Bool = true,
                             state: NSControl.StateValue = .off,
                             action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let proxy = MenuTargetProxy(handler: action)
        let mi = NSMenuItem(title: title,
                            action: #selector(MenuTargetProxy.fire(_:)),
                            keyEquivalent: shortcut?.key ?? "")
        mi.target = proxy
        mi.representedObject = proxy        // retain the proxy
        mi.identifier = NSUserInterfaceItemIdentifier(rawValue: id.rawValue)
        mi.toolTip = tooltip
        mi.isEnabled = enabled
        mi.state = state
        if let mods = shortcut?.mods {
            mi.keyEquivalentModifierMask = mods
        }
        return mi
    }

    private static func disabledItem(_ title: String,
                                     id: ContextMenuActions.ItemID,
                                     tooltip: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.identifier = NSUserInterfaceItemIdentifier(rawValue: id.rawValue)
        mi.toolTip = tooltip
        mi.isEnabled = false
        return mi
    }

    // MARK: - §7.1 File row

    static func fileRow(state: AppState, path: String) -> NSMenu {
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier(
            rawValue: ContextMenuActions.SurfaceID.fileRow.rawValue)

        let url = URL(fileURLWithPath: path)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let isImage = (UTType(filenameExtension: url.pathExtension)?
            .conforms(to: .image) ?? false)
        let missingTip = "This file no longer exists on disk."

        menu.addItem(item("Open", id: .open, shortcut: .returnKey) {
            ContextMenuActions.open(state: state, path: path)
        })
        menu.addItem(item("Open in New Window", id: .openInNewWindow,
                          shortcut: .cmdN) {
            ContextMenuActions.openInNewWindow(state: state, path: path)
        })
        menu.addItem(item("Open in Floating Viewer",
                          id: .openInFloatingViewer) {
            ContextMenuActions.openInFloatingViewer(state: state, path: path)
        })
        menu.addItem(openWithSubmenu(state: state, path: path,
                                     menu: .fileRow))
        menu.addItem(item("Quick Look", id: .quickLook, shortcut: .space) {
            ContextMenuActions.quickLook(state: state, path: path)
        })
        menu.addItem(NSMenuItem.separator())

        let revealItem = item("Reveal in Finder", id: .revealInFinder,
                              shortcut: .cmdR,
                              tooltip: exists ? nil : missingTip,
                              enabled: exists) {
            ContextMenuActions.revealInFinder(menu: .fileRow, path: path)
        }
        menu.addItem(revealItem)
        menu.addItem(item("Copy Image", id: .copyImage, shortcut: .cmdC,
                          tooltip: isImage ? nil
                                : "Disabled — not an image file.",
                          enabled: exists && isImage) {
            // Action target follows the panel cursor (set in §3.3 pre-fire).
            ContextMenuActions.copyImage(state: state, menu: .fileRow)
        })
        menu.addItem(item("Copy File Path", id: .copyFilePath,
                          shortcut: .ctrlCmdC) {
            ContextMenuActions.copyFilePath(state: state, menu: .fileRow)
        })
        menu.addItem(NSMenuItem.separator())

        // Include / Inherit / Don't Include — three states cycle.
        appendIncludeStateItems(to: menu, state: state, path: path,
                                isRoot: false, surface: .fileRow)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Show in File List", id: .showInFileList,
                          enabled: exists) {
            ContextMenuActions.showInFileList(state: state, path: path)
        })
        menu.addItem(item("Show Metadata", id: .showMetadata,
                          shortcut: .optCmdI) {
            // Toggles the on-image info overlay. ImageInfoOverlay reads
            // viewer.showInfoOverlay; the metadata panel ships in v2.
            state.viewer.showInfoOverlay.toggle()
            _ = ContextMenuActions.recordClick(menu: .fileRow,
                                               item: .showMetadata)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Set As Desktop Picture",
                          id: .setAsDesktopPicture,
                          tooltip: isImage ? nil
                                : "Disabled — not an image file.",
                          enabled: exists && isImage) {
            ContextMenuActions.setAsDesktopPicture(menu: .fileRow,
                                                   path: path)
        })
        menu.addItem(item("Rename…", id: .rename, shortcut: .f2,
                          enabled: exists) {
            ContextMenuActions.rename(state: state, menu: .fileRow)
        })
        menu.addItem(item("Move to Trash", id: .moveToTrash,
                          shortcut: .cmdDelete,
                          enabled: exists) {
            ContextMenuActions.moveToTrash(state: state, menu: .fileRow)
        })

        return menu
    }

    // MARK: - §7.2 Folder (subdirectory) row

    static func folderRow(state: AppState, path: String) -> NSMenu {
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier(
            rawValue: ContextMenuActions.SurfaceID.folderRow.rawValue)

        menu.addItem(item("Open in Floating File Tree",
                          id: .openInFloatingViewer,
                          shortcut: .ctrlCmdF) {
            FloatingFileTreeWindowController.shared.show(state: state)
        })
        menu.addItem(item("Expand Subtree", id: .expandSubtree,
                          shortcut: .optArrowR) {
            ContextMenuActions.expandSubtree(state: state, folderPath: path)
        })
        menu.addItem(item("Collapse Subtree", id: .collapseSubtree,
                          shortcut: .optArrowL) {
            ContextMenuActions.collapseSubtree(state: state, folderPath: path)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Reveal in Finder", id: .revealInFinder,
                          shortcut: .cmdR) {
            ContextMenuActions.revealInFinder(menu: .folderRow, path: path)
        })
        menu.addItem(item("Copy Folder Path", id: .copyFolderPath,
                          shortcut: .ctrlCmdC) {
            ContextMenuActions.copyFolderPath(menu: .folderRow, path: path)
        })
        menu.addItem(item("Open in Terminal", id: .openInTerminal) {
            ContextMenuActions.openInTerminal(menu: .folderRow, path: path)
        })
        menu.addItem(NSMenuItem.separator())

        appendIncludeStateItems(to: menu, state: state, path: path,
                                isRoot: false, surface: .folderRow)
        menu.addItem(disabledItem("Edit Filter for This Folder…",
                                  id: .editFilter,
                                  tooltip: "Per-folder filter editor coming in v2."))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Add Subfolder As Root", id: .addSubfolderAsRoot) {
            ContextMenuActions.addSubfolderAsRoot(state: state,
                                                  folderPath: path)
        })
        menu.addItem(disabledItem("Remove Folder from Scope",
                                  id: .removeFolderFromScope,
                                  tooltip: "Per-folder exclude editor coming in v2."))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Move Folder to Trash", id: .moveFolderToTrash,
                          shortcut: .shiftCmdDelete) {
            ContextMenuActions.moveFolderToTrash(menu: .folderRow,
                                                 path: path)
        })

        return menu
    }

    // MARK: - §7.3 Root row

    static func rootRow(state: AppState, rootPath: URL) -> NSMenu {
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier(
            rawValue: ContextMenuActions.SurfaceID.rootRow.rawValue)

        let path = rootPath.path
        let file = (try? DirectoriesStore.shared.load()) ?? DirectoriesFile()
        let idx = file.roots.firstIndex(where: { $0.path == rootPath })
        let count = file.roots.count
        let hasFilter = (file.roots.first(where: { $0.path == rootPath })?
            .filter.items.isEmpty == false)

        menu.addItem(item("Refresh This Root", id: .refreshThisRoot) {
            ContextMenuActions.refreshThisRoot(state: state,
                                               rootPath: rootPath)
        })
        menu.addItem(item("Refresh All Roots", id: .refreshAllRoots) {
            ContextMenuActions.refreshAllRoots(state: state,
                                               menu: .rootRow)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Reveal in Finder", id: .revealInFinder,
                          shortcut: .cmdR) {
            ContextMenuActions.revealInFinder(menu: .rootRow, path: path)
        })
        menu.addItem(item("Open in Terminal", id: .openInTerminal) {
            ContextMenuActions.openInTerminal(menu: .rootRow, path: path)
        })
        menu.addItem(item("Copy Folder Path", id: .copyFolderPath,
                          shortcut: .ctrlCmdC) {
            ContextMenuActions.copyFolderPath(menu: .rootRow, path: path)
        })
        menu.addItem(NSMenuItem.separator())

        // §7.3 / include_checks.mdx §1.0 — root rows are two-state.
        // Item 7 *Inherit* is disabled.
        appendIncludeStateItems(to: menu, state: state, path: path,
                                isRoot: true, surface: .rootRow)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(disabledItem("Edit Filter for This Root…",
                                  id: .editFilter,
                                  tooltip: "Per-root filter editor coming in v2."))
        menu.addItem(item("Clear Filter on This Root",
                          id: .clearFilter,
                          tooltip: hasFilter ? nil
                                : "Disabled — this root has no filter.",
                          enabled: hasFilter) {
            ContextMenuActions.clearFilterOnRoot(state: state,
                                                 rootPath: rootPath)
        })
        menu.addItem(NSMenuItem.separator())

        let isFirst = (idx == 0)
        let isLast = (idx == (count - 1))
        menu.addItem(item("Move Root Up", id: .moveRootUp,
                          enabled: !isFirst) {
            ContextMenuActions.moveRoot(state: state, rootPath: rootPath,
                                        direction: .up)
        })
        menu.addItem(item("Move Root Down", id: .moveRootDown,
                          enabled: !isLast) {
            ContextMenuActions.moveRoot(state: state, rootPath: rootPath,
                                        direction: .down)
        })
        menu.addItem(item("Move Root to Top", id: .moveRootToTop,
                          enabled: !isFirst) {
            ContextMenuActions.moveRoot(state: state, rootPath: rootPath,
                                        direction: .top)
        })
        menu.addItem(item("Move Root to Bottom", id: .moveRootToBottom,
                          enabled: !isLast) {
            ContextMenuActions.moveRoot(state: state, rootPath: rootPath,
                                        direction: .bottom)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Remove Directory from Scope",
                          id: .removeDirectory,
                          shortcut: .shiftCmdDelete,
                          tooltip: "Removes this directory from the scope. " +
                                   "Files on disk are not affected.") {
            ContextMenuActions.removeDirectory(state: state,
                                               rootPath: rootPath)
        })

        return menu
    }

    // MARK: - §7.4 Panel-empty

    static func panelEmpty(state: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier(
            rawValue: ContextMenuActions.SurfaceID.panelEmpty.rawValue)

        menu.addItem(item("Add Directory…", id: .addDirectory,
                          shortcut: .cmdD) {
            ContextMenuActions.addDirectoryFromPicker(state: state)
        })
        let clipboardHasFolder = clipboardContainsFolderPath()
        menu.addItem(item("Add Directory From Clipboard",
                          id: .addDirectoryFromClipboard,
                          tooltip: clipboardHasFolder ? nil
                                : "Disabled — the clipboard does not contain a folder path.",
                          enabled: clipboardHasFolder) {
            ContextMenuActions.addDirectoryFromClipboard(state: state)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(viewModeSubmenu(state: state))
        menu.addItem(sortBySubmenu(state: state))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Refresh All Roots", id: .refreshAllRoots) {
            ContextMenuActions.refreshAllRoots(state: state,
                                               menu: .panelEmpty)
        })
        menu.addItem(item("Re-evaluate Active Scope", id: .reevaluateScope,
                          shortcut: .cmdR) {
            ContextMenuActions.reevaluateScope(state: state,
                                               menu: .panelEmpty)
        })
        menu.addItem(item("Clear All Directories",
                          id: .clearAllDirectories) {
            ContextMenuActions.clearAllDirectories(state: state)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Reveal Local Storage in Finder",
                          id: .revealLocalStorage,
                          shortcut: .optCmdG) {
            ContextMenuActions.revealLocalStorage(menu: .panelEmpty)
        })

        return menu
    }

    // MARK: - §7.5 Panel-header

    static func panelHeader(state: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier(
            rawValue: ContextMenuActions.SurfaceID.panelHeader.rawValue)
        menu.addItem(viewModeSubmenu(state: state))
        menu.addItem(sortBySubmenu(state: state))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Hide Panel", id: .hidePanel, shortcut: .cmdL) {
            // The panel framework's `togglePanel("file_panel")` hook ships
            // in `panels.mdx` §5.6.1. Until that landing is wired here,
            // collapse the file_panel by hiding the floating tree window —
            // the visible behaviour matches the spec's "hide".
            FloatingFileTreeWindowController.shared.hide()
        })
        menu.addItem(disabledItem("Move Panel ▸", id: .openWith,
                                  tooltip: "Panel docking sub-menu lands with panels.mdx §5.2 wiring."))
        menu.addItem(disabledItem("Reset Panel Width", id: .openWith,
                                  tooltip: "Coming in v2."))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(disabledItem("Customize Panel Header…", id: .openWith,
                                  tooltip: "Coming in v2."))
        return menu
    }

    // MARK: - §7.7 Image canvas

    static func imageCanvas(state: AppState, viewer: ViewerState) -> NSMenu? {
        guard state.selectedFile != nil else { return nil }
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier(
            rawValue: ContextMenuActions.SurfaceID.viewerCanvas.rawValue)
        let path = state.selectedFile!

        menu.addItem(item("Next Image", id: .nextImage, shortcut: .arrowR) {
            ContextMenuActions.canvasNextImage(state: state, viewer: viewer)
        })
        menu.addItem(item("Previous Image", id: .previousImage,
                          shortcut: .arrowL) {
            ContextMenuActions.canvasPreviousImage(state: state, viewer: viewer)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Zoom to Fit", id: .zoomToFit, shortcut: .zKey,
                          state: viewer.zoomMode == .fit ? .on : .off) {
            ContextMenuActions.canvasZoomToFit(viewer: viewer)
        })
        menu.addItem(item("Zoom to Width", id: .zoomToWidth,
                          shortcut: .wKey,
                          state: viewer.zoomMode == .width ? .on : .off) {
            ContextMenuActions.canvasZoomToWidth(viewer: viewer)
        })
        menu.addItem(item("Actual Size", id: .zoomActual, shortcut: .nKey) {
            ContextMenuActions.canvasZoomActual(viewer: viewer)
        })
        menu.addItem(item("Lock Zoom", id: .lockZoom, shortcut: .ctrlCmdL,
                          state: viewer.zoomMode == .lock ? .on : .off) {
            viewer.zoomMode = (viewer.zoomMode == .lock) ? .fit : .lock
            _ = ContextMenuActions.recordClick(menu: .viewerCanvas,
                                               item: .lockZoom)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Rotate Left", id: .rotateLeft) {
            ContextMenuActions.canvasRotateLeft(viewer: viewer)
        })
        menu.addItem(item("Rotate Right", id: .rotateRight, shortcut: .cmdK) {
            ContextMenuActions.canvasRotateRight(viewer: viewer)
        })
        menu.addItem(item("Flip Horizontal", id: .flipHorizontal,
                          shortcut: .optCmdH,
                          state: viewer.flipHorizontal ? .on : .off) {
            ContextMenuActions.canvasFlipHorizontal(viewer: viewer)
        })
        menu.addItem(item("Flip Vertical", id: .flipVertical,
                          shortcut: .optCmdV,
                          state: viewer.flipVertical ? .on : .off) {
            ContextMenuActions.canvasFlipVertical(viewer: viewer)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(showChannelsSubmenu(viewer: viewer))
        menu.addItem(item("Color Picker", id: .colorPicker,
                          shortcut: .shiftCmdK,
                          state: viewer.showColorPicker ? .on : .off) {
            ContextMenuActions.canvasToggleColorPicker(viewer: viewer)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Copy Image", id: .copyImage, shortcut: .cmdC) {
            ContextMenuActions.copyImage(state: state, menu: .viewerCanvas)
        })
        menu.addItem(item("Copy File Path", id: .copyFilePath,
                          shortcut: .ctrlCmdC) {
            ContextMenuActions.copyFilePath(state: state,
                                            menu: .viewerCanvas)
        })
        menu.addItem(item("Reveal in Finder", id: .revealInFinder,
                          shortcut: .cmdR) {
            ContextMenuActions.revealInFinder(menu: .viewerCanvas, path: path)
        })
        menu.addItem(item("Show in Directory Panel",
                          id: .showInFileList) {
            ContextMenuActions.canvasShowInDirectoryPanel(state: state)
        })
        menu.addItem(item("Show Metadata", id: .showMetadata,
                          shortcut: .optCmdI,
                          state: viewer.showInfoOverlay ? .on : .off) {
            viewer.showInfoOverlay.toggle()
            _ = ContextMenuActions.recordClick(menu: .viewerCanvas,
                                               item: .showMetadata)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Save As…", id: .saveAs, shortcut: .shiftCmdS) {
            ContextMenuActions.saveAs(state: state)
        })
        menu.addItem(convertToSubmenu(state: state))
        menu.addItem(openWithSubmenu(state: state, path: path,
                                     menu: .viewerCanvas))
        menu.addItem(item("Print…", id: .print, shortcut: .cmdP) {
            ContextMenuActions.print(state: state)
        })
        menu.addItem(NSMenuItem.separator())

        menu.addItem(item("Set As Desktop Picture",
                          id: .setAsDesktopPicture) {
            ContextMenuActions.setAsDesktopPicture(menu: .viewerCanvas,
                                                   path: path)
        })
        menu.addItem(item("Move to Trash", id: .moveToTrash,
                          shortcut: .cmdDelete) {
            ContextMenuActions.moveToTrash(state: state,
                                           menu: .viewerCanvas)
        })

        return menu
    }

    // MARK: - §7.15 Status bar

    static func statusBar(state: AppState,
                          rawText: String) -> some View {
        Group {
            Button("Copy Status Text") {
                ContextMenuActions.copyStatusText(text: rawText)
            }
            Divider()
            Button("Re-evaluate Active Scope") {
                ContextMenuActions.reevaluateScope(state: state,
                                                   menu: .statusBar)
            }
            Button("Reveal Local Storage in Finder") {
                ContextMenuActions.revealLocalStorage(menu: .statusBar)
            }
        }
    }

    // MARK: - Shared sub-menu builders

    /// §7.4 / §7.5 sub-menu — *Switch View ▸* with the active mode
    /// checkmarked.
    private static func viewModeSubmenu(state: AppState) -> NSMenuItem {
        let parent = NSMenuItem(title: "Switch View", action: nil,
                                keyEquivalent: "")
        let sub = NSMenu(title: "Switch View")
        let treeItem = item("Tree", id: .switchViewTree,
                            state: state.panelViewMode == .tree ? .on : .off) {
            ContextMenuActions.setPanelView(state: state, mode: .tree)
        }
        let listItem = item("List", id: .switchViewList,
                            state: state.panelViewMode == .list ? .on : .off) {
            ContextMenuActions.setPanelView(state: state, mode: .list)
        }
        sub.addItem(treeItem)
        sub.addItem(listItem)
        parent.submenu = sub
        return parent
    }

    /// §7.4 / §7.5 sub-menu — *Sort By ▸* with the active sort key
    /// checkmarked, plus the Ascending / Descending toggles. The v1
    /// implementation logs the user's choice but does not persist it
    /// because the panel's sort field is shipping with `list_of_files.mdx`
    /// §3A.9; until that lands the items are wired but functionally
    /// no-ops, with the correct on/off marks.
    private static func sortBySubmenu(state: AppState) -> NSMenuItem {
        let parent = NSMenuItem(title: "Sort By", action: nil,
                                keyEquivalent: "")
        let sub = NSMenu(title: "Sort By")
        let names: [(String, ContextMenuActions.ItemID)] = [
            ("Name",          .sortByName),
            ("Date Modified", .sortByDateModified),
            ("Date Created",  .sortByDateCreated),
            ("Size",          .sortBySize),
            ("Kind",          .sortByKind),
        ]
        for (label, id) in names {
            sub.addItem(item(label, id: id) {
                _ = ContextMenuActions.recordClick(menu: .panelEmpty,
                                                   item: id)
            })
        }
        sub.addItem(NSMenuItem.separator())
        sub.addItem(item("Ascending", id: .sortAscending, state: .on) {
            _ = ContextMenuActions.recordClick(menu: .panelEmpty,
                                               item: .sortAscending)
        })
        sub.addItem(item("Descending", id: .sortDescending) {
            _ = ContextMenuActions.recordClick(menu: .panelEmpty,
                                               item: .sortDescending)
        })
        parent.submenu = sub
        return parent
    }

    /// §7.7 sub-menu — *Show Channels ▸*. Mirrors `ColorChannel` cases.
    private static func showChannelsSubmenu(viewer: ViewerState) -> NSMenuItem {
        let parent = NSMenuItem(title: "Show Channels", action: nil,
                                keyEquivalent: "")
        let sub = NSMenu(title: "Show Channels")
        let mapping: [(String, ContextMenuActions.ItemID, ColorChannel)] = [
            ("All",        .showChannelsAll,       .all),
            ("Red Only",   .showChannelsRed,       .red),
            ("Green Only", .showChannelsGreen,     .green),
            ("Blue Only",  .showChannelsBlue,      .blue),
            ("Alpha as Gray", .showChannelsAlpha,  .alpha),
        ]
        for (label, id, channel) in mapping {
            sub.addItem(item(label, id: id,
                             state: viewer.colorChannel == channel ? .on : .off) {
                viewer.colorChannel = channel
                _ = ContextMenuActions.recordClick(menu: .viewerCanvas,
                                                   item: id)
            })
        }
        parent.submenu = sub
        return parent
    }

    /// §7.7 sub-menu — *Convert To ▸*. The leaves open `NSSavePanel`
    /// with the matching `NSBitmapImageRep.FileType`.
    private static func convertToSubmenu(state: AppState) -> NSMenuItem {
        let parent = NSMenuItem(title: "Convert To", action: nil,
                                keyEquivalent: "")
        let sub = NSMenu(title: "Convert To")
        let entries: [(String, String, ContextMenuActions.ItemID,
                       NSBitmapImageRep.FileType)] = [
            ("PNG",  "png",  .convertToPNG,  .png),
            ("JPEG", "jpg",  .convertToJPEG, .jpeg),
            ("TIFF", "tiff", .convertToTIFF, .tiff),
            ("HEIC", "heic", .convertToHEIC, .tiff),  // HEIC not native; fallback to TIFF
            ("WebP", "webp", .convertToWebP, .png),   // WebP not native; fallback
            ("AVIF", "avif", .convertToAVIF, .png),   // AVIF not native; fallback
            ("JXL",  "jxl",  .convertToJXL,  .png),   // JXL not native; fallback
            ("GIF",  "gif",  .convertToPNG,  .gif),
            ("BMP",  "bmp",  .convertToPNG,  .bmp),
        ]
        for (label, ext, id, bmp) in entries {
            sub.addItem(item(label, id: id) {
                ContextMenuActions.convertTo(state: state, item: id,
                                             ext: ext, bitmapType: bmp)
            })
        }
        parent.submenu = sub
        return parent
    }

    // MARK: - §7.1.1 Open With sub-menu

    /// Built lazily via `NSMenuDelegate.menuNeedsUpdate(_:)` so the
    /// system app-list query does not block the parent menu's open.
    private static func openWithSubmenu(state: AppState, path: String,
                                        menu surface: ContextMenuActions.SurfaceID) -> NSMenuItem {
        let parent = NSMenuItem(title: "Open With", action: nil,
                                keyEquivalent: "")
        parent.identifier = NSUserInterfaceItemIdentifier(
            rawValue: ContextMenuActions.ItemID.openWith.rawValue)
        let sub = NSMenu(title: "Open With")
        let delegate = OpenWithMenuDelegate(state: state, path: path,
                                            surface: surface)
        sub.delegate = delegate
        // Retain the delegate via representedObject — NSMenu does not
        // strong-reference its delegate.
        parent.representedObject = delegate
        parent.submenu = sub
        return parent
    }

    // MARK: - Helpers

    /// §7.1 / §7.2 — append the three (or two, on root) include-state
    /// items with the correct checkmark on the row's *explicit* state.
    private static func appendIncludeStateItems(
        to menu: NSMenu, state: AppState, path: String, isRoot: Bool,
        surface: ContextMenuActions.SurfaceID
    ) {
        let roots = state.walkerRoots
        let root = IncludeStateController.root(for: path, in: roots)
        let explicit: IncludeState = {
            guard let root else { return .inherit }
            if isRoot { return root.defaultIncludeState }
            let rel = IncludePath.relative(absolutePath: path, root: root.path)
            return root.explicitState(for: rel)
        }()
        menu.addItem(item("Include in Scope", id: .include,
                          shortcut: .ctrl1,
                          state: explicit == .include ? .on : .off) {
            ContextMenuActions.setIncludeState(state: state, path: path,
                                               target: .include,
                                               menu: surface)
        })
        if isRoot {
            menu.addItem(disabledItem("Inherit Include State",
                                      id: .inherit,
                                      tooltip: "A root has no ancestor to inherit from."))
        } else {
            menu.addItem(item("Inherit Include State", id: .inherit,
                              shortcut: .ctrl2,
                              state: explicit == .inherit ? .on : .off) {
                ContextMenuActions.setIncludeState(state: state, path: path,
                                                   target: .inherit,
                                                   menu: surface)
            })
        }
        menu.addItem(item("Don't Include in Scope", id: .dontInclude,
                          shortcut: .ctrl3,
                          state: explicit == .exclude ? .on : .off) {
            ContextMenuActions.setIncludeState(state: state, path: path,
                                               target: .exclude,
                                               menu: surface)
        })
    }

    private static func clipboardContainsFolderPath() -> Bool {
        guard let s = NSPasteboard.general.string(forType: .string) else {
            return false
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let expanded = AppPaths.expandTilde(trimmed)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded,
                                                    isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}

// MARK: - MenuTargetProxy

/// Strong-typed `target/action` pair for an `NSMenuItem` whose handler
/// is a Swift closure. Held alive by the menu item via
/// `representedObject` so the closure outlives the builder call.
@MainActor
final class MenuTargetProxy: NSObject {
    private let handler: @MainActor () -> Void
    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }
    @objc func fire(_ sender: Any?) { handler() }
}

// MARK: - OpenWithMenuDelegate

/// Lazy builder for the §7.1.1 *Open With ▸* sub-menu. Populates the
/// items on hover (`menuNeedsUpdate(_:)`) so the expensive
/// `NSWorkspace.urlsForApplications(toOpen:)` call does not delay the
/// parent menu's open animation.
@MainActor
final class OpenWithMenuDelegate: NSObject, NSMenuDelegate {
    let state: AppState
    let path: String
    let surface: ContextMenuActions.SurfaceID
    private var built = false

    init(state: AppState, path: String,
         surface: ContextMenuActions.SurfaceID) {
        self.state = state
        self.path = path
        self.surface = surface
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        if built { return }
        built = true
        menu.removeAllItems()
        let url = URL(fileURLWithPath: path)
        let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: url)

        // Default app.
        if let defaultURL {
            let title = "\(defaultURL.deletingPathExtension().lastPathComponent) (default)"
            menu.addItem(makeItem(title: title, appURL: defaultURL,
                                  identifier: defaultURL.lastPathComponent))
            menu.addItem(NSMenuItem.separator())
        }

        // Other candidates.
        let others = candidates.filter { $0 != defaultURL }
        for app in others.prefix(20) {
            let title = app.deletingPathExtension().lastPathComponent
            menu.addItem(makeItem(title: title, appURL: app,
                                  identifier: app.lastPathComponent))
        }

        // Registered external tools.
        let tools = (try? ExternalToolStorage.shared.listTools()) ?? []
        if !tools.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for tool in tools {
                let title = tool.displayName
                let proxy = MenuTargetProxy { [path] in
                    _ = ContextMenuActions.recordClick(menu: self.surface,
                                                       item: .openWith,
                                                       extra: [("with",
                                                                "tool.\(tool.id)"),
                                                               ("path", path)])
                    _ = try? ExternalToolLauncher().launch(tool, filePath: path)
                }
                let mi = NSMenuItem(title: title,
                                    action: #selector(MenuTargetProxy.fire(_:)),
                                    keyEquivalent: "")
                mi.target = proxy
                mi.representedObject = proxy
                mi.identifier = NSUserInterfaceItemIdentifier(
                    rawValue: "open-with.tool.\(tool.id)")
                menu.addItem(mi)
            }
        }

        // App Store + Other.
        menu.addItem(NSMenuItem.separator())
        let appStoreProxy = MenuTargetProxy {
            _ = ContextMenuActions.recordClick(menu: self.surface,
                                               item: .openWithAppStore)
            if let url = URL(string: "macappstore://") {
                NSWorkspace.shared.open(url)
            }
        }
        let appStore = NSMenuItem(title: "App Store…",
                                  action: #selector(MenuTargetProxy.fire(_:)),
                                  keyEquivalent: "")
        appStore.target = appStoreProxy
        appStore.representedObject = appStoreProxy
        appStore.identifier = NSUserInterfaceItemIdentifier(
            rawValue: ContextMenuActions.ItemID.openWithAppStore.rawValue)
        menu.addItem(appStore)

        let otherProxy = MenuTargetProxy { [path, state, surface] in
            ContextMenuActions.openWithOther(state: state, path: path,
                                             menu: surface)
        }
        let other = NSMenuItem(title: "Other…",
                               action: #selector(MenuTargetProxy.fire(_:)),
                               keyEquivalent: "")
        other.target = otherProxy
        other.representedObject = otherProxy
        other.identifier = NSUserInterfaceItemIdentifier(
            rawValue: ContextMenuActions.ItemID.openWithOther.rawValue)
        menu.addItem(other)
    }

    private func makeItem(title: String, appURL: URL,
                          identifier: String) -> NSMenuItem {
        let proxy = MenuTargetProxy { [path, state, surface] in
            ContextMenuActions.openWith(state: state, path: path,
                                        appURL: appURL, menu: surface,
                                        identifier: appURL.lastPathComponent)
        }
        let mi = NSMenuItem(title: title,
                            action: #selector(MenuTargetProxy.fire(_:)),
                            keyEquivalent: "")
        mi.target = proxy
        mi.representedObject = proxy
        mi.image = NSWorkspace.shared.icon(forFile: appURL.path).copy() as? NSImage
        mi.image?.size = NSSize(width: 16, height: 16)
        mi.identifier = NSUserInterfaceItemIdentifier(
            rawValue: "open-with.\(identifier)")
        return mi
    }
}
