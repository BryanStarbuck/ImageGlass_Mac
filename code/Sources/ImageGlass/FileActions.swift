import AppKit
import Foundation
import ImageGlassCore
import UniformTypeIdentifiers

/// File-action surface for ImageGlass_Mac. Implements the five verbs in
/// `docs/use_cases/actions.mdx` (Rename, Move to Trash, Copy Image, Copy
/// File Path, Print) plus the New Window verb. Every public method
/// emits a single key=value audit line through `MCPAuditLogger` matching
/// the formats in §2.6 / §3.5 / §4.5 / §5.5 / §6.5 of the spec so a
/// debugger or XCUITest run can replay the session.
///
/// All methods are `@MainActor` because they touch `AppState`,
/// `NSPasteboard`, `NSPrintOperation`, and `NSAlert`. The MCP-callable
/// thin wrappers in `FileActionsMCP.swift` route to these methods.
@MainActor
enum FileActions {

    // MARK: - Source tags
    //
    // Every action records a `source=` tag so the audit log distinguishes
    // a menu click from a keystroke from an MCP call. Use these constants
    // to keep the spelling consistent across surfaces.

    enum Source: String {
        case menuFile = "menu:File"
        case menuEdit = "menu:Edit"
        case keyF2 = "key:F2"
        case keyP = "key:P"
        case keyCmdC = "key:cmd-c"
        case keyCmdP = "key:cmd-p"
        case keyCmdN = "key:cmd-n"
        case keyCmdDelete = "key:cmd-delete"
        case keyCtrlCmdC = "key:ctrl-cmd-c"
        case panelInline = "panel:rename"
        case context = "menu:context"
        case mcp = "mcp"
    }

    // MARK: - Target resolution (spec §1.1)

    /// Resolves "the file the user means" per the spec's target rule. The
    /// caller passes the directory-panel cursor explicitly so this stays
    /// pure — `AppState` is the source of truth for both fields, but
    /// callers in different focus contexts pass them as parameters so a
    /// unit test can exercise the rule without a SwiftUI surface.
    static func resolveTarget(selectedFile: String?, panelCursor: String?) -> String? {
        // Prefer the panel cursor when it is on an actual file row. The
        // panel cursor may be parked on a folder; folder rows are not
        // valid file-action targets (the menu items disable them).
        if let cursor = panelCursor, !cursor.isEmpty,
           let isDir = try? URL(fileURLWithPath: AppPaths.expandTilde(cursor))
            .resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
           isDir == false {
            return cursor
        }
        return selectedFile
    }

    // MARK: - Rename (spec §2)

    /// Result for the rename verb. Used by both GUI and MCP surfaces.
    struct RenameResult {
        var ok: Bool
        var newPath: String?
        var err: String?
    }

    /// Open the macOS confirm-style sheet for renaming the target and,
    /// on commit, perform the rename. Validation rules and the
    /// preserve-extension fallback follow spec §2.4. Called from the
    /// File menu and from `F2`.
    @discardableResult
    static func renameViaSheet(state: AppState, source: Source) -> RenameResult {
        // docs/performance.mdx §5 / §10.12 — `FileAction.Rename` wraps
        // the user-visible end-to-end rename (sheet open through commit).
        let _trace = PerformanceLog.shared.start(
            "FileAction.Rename",
            extra: [("source", source.rawValue)]
        )
        defer { _trace.finish() }
        guard let path = resolveTarget(selectedFile: state.selectedFile,
                                       panelCursor: state.treeNav.activeRow)
        else { return RenameResult(ok: false, err: "no_target") }

        let oldURL = URL(fileURLWithPath: AppPaths.expandTilde(path))
        let oldName = oldURL.lastPathComponent
        let oldExt = oldURL.pathExtension
        let oldBase = oldURL.deletingPathExtension().lastPathComponent

        let alert = NSAlert()
        alert.messageText = "Rename Image"
        alert.informativeText = "Old name: \(oldName)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = oldBase
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        // Focus the field, select the basename so the user can type to
        // replace; Finder does the same.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else {
            return RenameResult(ok: false, err: "cancelled")
        }

        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return commitRename(state: state, oldPath: path, oldExt: oldExt,
                            newRawName: typed, source: source)
    }

    /// Validate and commit a rename without UI. The MCP tool and the
    /// inline panel editor both end up here.
    @discardableResult
    static func commitRename(state: AppState, oldPath: String, oldExt: String?,
                             newRawName: String, source: Source) -> RenameResult {
        let corr = MCPAuditLogger.newCorrelationId()
        let oldURL = URL(fileURLWithPath: AppPaths.expandTilde(oldPath))
        let parent = oldURL.deletingLastPathComponent()
        let trimmed = newRawName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Spec §2.4 — validation rules. Each branch logs a distinct err
        // so the failure mode is debuggable.
        if trimmed.isEmpty { return logRenameFail(oldPath, "name_empty", source, corr) }
        if trimmed.contains("/") || trimmed.contains("\\") {
            return logRenameFail(oldPath, "name_has_path_sep", source, corr)
        }
        if trimmed.contains("\0") { return logRenameFail(oldPath, "name_invalid", source, corr) }
        if trimmed == "." || trimmed == ".." {
            return logRenameFail(oldPath, "name_invalid", source, corr)
        }

        // Spec §2.4 — preserve-extension fallback. If the user typed
        // "beach_notes" and the original was "notes_old.png", append
        // ".png" so the user does not lose the extension by accident.
        let preserve = state.settings.actions.rename_preserve_extension
        var finalName = trimmed
        if preserve, let ext = oldExt, !ext.isEmpty,
           (finalName as NSString).pathExtension.isEmpty {
            finalName += "." + ext
        }

        let destURL = parent.appendingPathComponent(finalName)

        // Same-path no-op (case-insensitive on APFS).
        if destURL.path.compare(oldURL.path,
                                options: [.caseInsensitive]) == .orderedSame {
            return RenameResult(ok: true, newPath: oldURL.path)
        }

        // Collision check — refuse if the destination exists and is not
        // the source (some filesystems are case-preserving and would let
        // the move succeed silently).
        if FileManager.default.fileExists(atPath: destURL.path) {
            return logRenameFail(oldPath, "name_collides", source, corr)
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: destURL)
        } catch let err as NSError {
            let code = (err.domain == NSCocoaErrorDomain
                        && err.code == NSFileWriteNoPermissionError)
                ? "permission_denied" : "src_missing"
            return logRenameFail(oldPath, code, source, corr)
        }

        // Patch in-memory references so the viewer follows without a flicker.
        let newPath = destURL.path
        if state.selectedFile == oldPath {
            state.selectedFile = newPath
        }
        // Patch the saved last-selected path for every persisted window
        // record (spec §7.7).
        if state.settings.window.last_selected_file == oldPath {
            state.settings.window.last_selected_file = newPath
            Task { await state.saveSettings() }
        }

        MCPAuditLogger.shared.log([
            ("tool", "file.rename"),
            ("from", oldURL.path),
            ("to", newPath),
            ("source", source.rawValue),
            ("corr", corr),
            ("ok", "true"),
        ])

        return RenameResult(ok: true, newPath: newPath)
    }

    private static func logRenameFail(_ oldPath: String, _ err: String,
                                      _ source: Source, _ corr: String) -> RenameResult {
        MCPAuditLogger.shared.log([
            ("tool", "file.rename"),
            ("from", oldPath),
            ("source", source.rawValue),
            ("corr", corr),
            ("ok", "false"),
            ("err", err),
        ])
        return RenameResult(ok: false, err: err)
    }

    // MARK: - Move to Trash (spec §3)

    struct TrashResult {
        var ok: Bool
        var trashURL: URL?
        var err: String?
    }

    /// Move the resolved target to the Trash. Shows the confirmation
    /// dialog unless `settings.actions.confirm_move_to_trash == false`
    /// or `force == true` (the MCP path forces it — spec §3.2).
    @discardableResult
    static func moveToTrash(state: AppState, source: Source,
                            force: Bool = false) -> TrashResult {
        // docs/performance.mdx §5 / §10.12 — `FileAction.Delete`
        // (move-to-trash). Wraps optional confirm dialog + trashItem.
        let _trace = PerformanceLog.shared.start(
            "FileAction.Delete",
            extra: [("source", source.rawValue), ("force", force ? "true" : "false")]
        )
        defer { _trace.finish() }
        guard let path = resolveTarget(selectedFile: state.selectedFile,
                                       panelCursor: state.treeNav.activeRow)
        else { return TrashResult(ok: false, err: "no_target") }

        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        if !force && state.settings.actions.confirm_move_to_trash {
            let alert = NSAlert()
            alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
            alert.informativeText = "You can put it back later from the Trash."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                state.settings.actions.confirm_move_to_trash = false
                Task { await state.saveSettings() }
            }
            if response != .alertFirstButtonReturn {
                return TrashResult(ok: false, err: "cancelled")
            }
        }
        return commitTrash(state: state, url: url, source: source)
    }

    @discardableResult
    private static func commitTrash(state: AppState, url: URL,
                                    source: Source) -> TrashResult {
        let corr = MCPAuditLogger.newCorrelationId()
        var resulting: NSURL? = nil
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch let err as NSError {
            let code = (err.domain == NSCocoaErrorDomain
                        && err.code == NSFileWriteNoPermissionError)
                ? "permission_denied" : "src_missing"
            MCPAuditLogger.shared.log([
                ("tool", "file.trash"),
                ("from", url.path),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "false"),
                ("err", code),
            ])
            return TrashResult(ok: false, err: code)
        }

        // Advance the selection per spec §3.4 — same policy as the
        // right-arrow: prefer the next file in display order, fall back
        // to the previous, then nil.
        if state.selectedFile == url.path
            || state.selectedFile == AppPaths.expandTilde(url.path) {
            let files = state.resolvedFiles
            if let idx = files.firstIndex(of: state.selectedFile ?? "") {
                if idx + 1 < files.count {
                    state.selectedFile = files[idx + 1]
                } else if idx > 0 {
                    state.selectedFile = files[idx - 1]
                } else {
                    state.selectedFile = nil
                }
            } else {
                state.selectedFile = state.resolvedFiles.first
            }
        }
        if state.settings.window.last_selected_file == url.path {
            state.settings.window.last_selected_file = state.selectedFile
            Task { await state.saveSettings() }
        }

        let trashURL = resulting as URL?
        var pairs: [(String, String)] = [
            ("tool", "file.trash"),
            ("from", url.path),
        ]
        if let trashURL { pairs.append(("trash", trashURL.path)) }
        pairs.append(("source", source.rawValue))
        pairs.append(("corr", corr))
        pairs.append(("ok", "true"))
        MCPAuditLogger.shared.log(pairs)

        return TrashResult(ok: true, trashURL: trashURL)
    }

    // MARK: - Copy Image (spec §4)

    struct CopyImageResult {
        var ok: Bool
        var byteCount: Int
        var err: String?
    }

    /// Decode the target image through `NSImage` and put a PNG + TIFF
    /// representation pair onto the system pasteboard. Spec §4.2.
    @discardableResult
    static func copyImageToClipboard(state: AppState, source: Source) -> CopyImageResult {
        // docs/performance.mdx §5 / §10.12 — `FileAction.CopyImage`.
        // Decoder + pasteboard write; dominant cost is the decode.
        let _trace = PerformanceLog.shared.start(
            "FileAction.CopyImage",
            extra: [("source", source.rawValue)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
        guard let path = resolveTarget(selectedFile: state.selectedFile,
                                       panelCursor: state.treeNav.activeRow)
        else {
            MCPAuditLogger.shared.log([
                ("tool", "file.copy_image"),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "false"),
                ("err", "no_target"),
            ])
            return CopyImageResult(ok: false, byteCount: 0, err: "no_target")
        }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard let img = NSImage(contentsOf: url),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            MCPAuditLogger.shared.log([
                ("tool", "file.copy_image"),
                ("path", url.path),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "false"),
                ("err", "decode_failed"),
            ])
            return CopyImageResult(ok: false, byteCount: 0, err: "decode_failed")
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        let ok = pb.writeObjects([item])
        if !ok {
            MCPAuditLogger.shared.log([
                ("tool", "file.copy_image"),
                ("path", url.path),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "false"),
                ("err", "pasteboard_write"),
            ])
            return CopyImageResult(ok: false, byteCount: 0, err: "pasteboard_write")
        }

        MCPAuditLogger.shared.log([
            ("tool", "file.copy_image"),
            ("path", url.path),
            ("bytes", String(png.count)),
            ("source", source.rawValue),
            ("corr", corr),
            ("ok", "true"),
        ])
        return CopyImageResult(ok: true, byteCount: png.count, err: nil)
    }

    // MARK: - Copy File Path (spec §5)

    struct CopyPathResult {
        var ok: Bool
        var copiedPath: String?
        var note: String?
    }

    /// Place the absolute POSIX path of the target file onto the system
    /// pasteboard as plain text. Spec §5.2. Missing files still produce
    /// `ok=true note=missing` so the user can paste a path even when the
    /// file has just been moved.
    @discardableResult
    static func copyFilePath(state: AppState, source: Source) -> CopyPathResult {
        // docs/performance.mdx §5 / §10.12 — `FileAction.CopyPath`.
        let _trace = PerformanceLog.shared.start(
            "FileAction.CopyPath",
            extra: [("source", source.rawValue)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
        guard let path = resolveTarget(selectedFile: state.selectedFile,
                                       panelCursor: state.treeNav.activeRow)
        else {
            MCPAuditLogger.shared.log([
                ("tool", "file.copy_path"),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "false"),
                ("err", "no_target"),
            ])
            return CopyPathResult(ok: false, copiedPath: nil, note: "no_target")
        }
        let absolute = AppPaths.expandTilde(path)
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setString(absolute, forType: .string)
        if !ok {
            MCPAuditLogger.shared.log([
                ("tool", "file.copy_path"),
                ("path", absolute),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "false"),
                ("err", "pasteboard_write"),
            ])
            return CopyPathResult(ok: false, copiedPath: nil, note: "pasteboard_write")
        }

        var pairs: [(String, String)] = [
            ("tool", "file.copy_path"),
            ("path", absolute),
            ("source", source.rawValue),
            ("corr", corr),
            ("ok", "true"),
        ]
        var note: String? = nil
        if !FileManager.default.fileExists(atPath: absolute) {
            pairs.append(("note", "missing"))
            note = "missing"
        }
        MCPAuditLogger.shared.log(pairs)
        return CopyPathResult(ok: true, copiedPath: absolute, note: note)
    }

    // MARK: - Print (spec §6)

    struct PrintResult {
        var ok: Bool
        var err: String?
    }

    /// Open the macOS print panel for the target image. Modal — the
    /// completion handler emits the `file.print_commit` (or `_cancel`)
    /// audit line. Spec §6.5.
    @discardableResult
    static func printImage(state: AppState, source: Source) -> PrintResult {
        // docs/performance.mdx §5 / §10.12 — `FileAction.Print` covers
        // up through `runModal`; the modal completion handler is the
        // user's commit step (separately auditable via the audit log).
        let _trace = PerformanceLog.shared.start(
            "FileAction.Print",
            extra: [("source", source.rawValue)]
        )
        defer { _trace.finish() }
        let corr = MCPAuditLogger.newCorrelationId()
        guard let path = resolveTarget(selectedFile: state.selectedFile,
                                       panelCursor: state.treeNav.activeRow)
        else {
            MCPAuditLogger.shared.log([
                ("tool", "file.print_open"),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "false"),
                ("err", "no_target"),
            ])
            return PrintResult(ok: false, err: "no_target")
        }
        let url = URL(fileURLWithPath: AppPaths.expandTilde(path))
        guard let img = NSImage(contentsOf: url) else {
            MCPAuditLogger.shared.log([
                ("tool", "file.print_open"),
                ("path", url.path),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "false"),
                ("err", "decode_failed"),
            ])
            return PrintResult(ok: false, err: "decode_failed")
        }

        MCPAuditLogger.shared.log([
            ("tool", "file.print_open"),
            ("path", url.path),
            ("source", source.rawValue),
            ("corr", corr),
            ("ok", "true"),
        ])

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0,
                                                  width: img.size.width,
                                                  height: img.size.height))
        imageView.image = img
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true

        let op = NSPrintOperation(view: imageView, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true

        let attachWin = NSApp.keyWindow ?? NSApp.mainWindow
        if let attachWin {
            op.runModal(for: attachWin,
                        delegate: PrintDelegate.shared,
                        didRun: #selector(PrintDelegate.didRun(_:success:contextInfo:)),
                        contextInfo: nil)
        } else {
            let success = op.run()
            logPrintCommit(path: url.path, success: success, info: info, source: source)
        }

        return PrintResult(ok: true, err: nil)
    }

    fileprivate static func logPrintCommit(path: String, success: Bool,
                                           info: NSPrintInfo, source: Source) {
        let corr = MCPAuditLogger.newCorrelationId()
        if success {
            let printer = info.printer.name
            MCPAuditLogger.shared.log([
                ("tool", "file.print_commit"),
                ("path", path),
                ("printer", printer),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "true"),
            ])
        } else {
            MCPAuditLogger.shared.log([
                ("tool", "file.print_cancel"),
                ("path", path),
                ("source", source.rawValue),
                ("corr", corr),
                ("ok", "true"),
            ])
        }
    }
}

/// Bridge for `NSPrintOperation.runModal` so we can emit the
/// commit/cancel audit line after the modal closes (the sync `run()`
/// path is used as a fallback above).
@MainActor
final class PrintDelegate: NSObject {
    static let shared = PrintDelegate()

    @objc func didRun(_ op: NSPrintOperation, success: Bool,
                      contextInfo: UnsafeMutableRawPointer?) {
        let path = (op.view as? NSImageView)?.image?.name() ?? ""
        FileActions.logPrintCommit(path: path, success: success,
                                   info: op.printInfo, source: .keyCmdP)
    }
}
