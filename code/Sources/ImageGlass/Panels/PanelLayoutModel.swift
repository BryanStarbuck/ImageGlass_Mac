import Foundation
import Observation
import SwiftUI
import ImageGlassCore

/// Observable wrapper around `PanelLayout`. The view tree observes this so
/// changes (from the GUI or from `FSEventStream` after an MCP edit) re-render.
/// Spec §8.3.
@MainActor
@Observable
public final class PanelLayoutModel {
    public private(set) var layout: PanelLayout

    /// File watcher for `layout.json`. When an MCP-driven edit lands, this
    /// reloads the file and republishes. Spec §6.4.
    private var watcher: FileWatcher?

    public init(layout: PanelLayout = LayoutStore.shared.load()) {
        self.layout = layout
    }

    /// Start watching `layout.json` and the presets dir for external edits
    /// (typically from MCP).
    public func startWatching() {
        stopWatching()
        do {
            try AppPaths.ensureLayoutDirectories()
        } catch {
            ErrorLog.log("AppPaths.ensureLayoutDirectories failed",
                         error: error,
                         class: String(describing: Self.self))
        }
        let w = FileWatcher(url: AppPaths.layoutDir) { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
        w.start()
        self.watcher = w
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    public func reloadFromDisk() {
        let new = LayoutStore.shared.load()
        if new != self.layout {
            self.layout = new
        }
    }

    // MARK: - Mutators (mirror the MCP surface)

    public func showPanel(_ id: String) {
        let descriptor = BuiltInPanelCatalog.descriptor(for: id)
        let new = PanelLayoutMutations.showPanel(
            layout,
            id: id,
            defaultPosition: descriptor?.defaultPosition ?? .right,
            defaultSize: descriptor?.preferredSize ?? .init(width: 280, height: 600)
        )
        apply(new)
    }

    /// Restore a panel and place it as the first (active) tab in its
    /// destination group. See `PanelLayoutMutations.showPanelAsPrimary`
    /// and docs/panels.mdx §6.5 (bootstrap reconciliation).
    public func showPanelAsPrimary(_ id: String) {
        let descriptor = BuiltInPanelCatalog.descriptor(for: id)
        let new = PanelLayoutMutations.showPanelAsPrimary(
            layout,
            id: id,
            defaultPosition: descriptor?.defaultPosition ?? .left,
            defaultSize: descriptor?.preferredSize ?? .init(width: 280, height: 600)
        )
        apply(new)
    }

    public func hidePanel(_ id: String) {
        do {
            let new = try PanelLayoutMutations.hidePanel(layout, id: id)
            apply(new)
        } catch {
            ErrorLog.log("PanelLayoutMutations.hidePanel failed for id '\(id)'",
                         error: error,
                         class: String(describing: Self.self))
        }
    }

    public func togglePanel(_ id: String) {
        if layout.isVisible(id) {
            hidePanel(id)
        } else {
            showPanel(id)
        }
    }

    public func movePanel(_ id: String, to position: DockPosition) {
        let descriptor = BuiltInPanelCatalog.descriptor(for: id)
        if position == .floating, descriptor?.supportsFloating == false { return }
        do {
            let new = try PanelLayoutMutations.movePanel(
                layout,
                id: id,
                to: position,
                preferredSize: descriptor?.preferredSize ?? .init(width: 320, height: 600)
            )
            apply(new)
        } catch {
            ErrorLog.log("PanelLayoutMutations.movePanel failed for id '\(id)' -> \(position)",
                         error: error,
                         class: String(describing: Self.self))
        }
    }

    public func setSize(panelID: String, size: CGFloat) {
        do {
            let new = try PanelLayoutMutations.setPanelSize(layout, id: panelID, size: size)
            apply(new)
        } catch {
            ErrorLog.log("PanelLayoutMutations.setPanelSize failed for id '\(panelID)' size=\(size)",
                         error: error,
                         class: String(describing: Self.self))
        }
    }

    public func activateTab(in groupID: UUID, panel id: String) {
        var new = layout
        if let gIdx = new.groups.firstIndex(where: { $0.id == groupID }),
           let pIdx = new.groups[gIdx].panelIDs.firstIndex(of: id) {
            new.groups[gIdx].activeIndex = pIdx
            apply(new)
        }
    }

    public func applyPreset(_ name: String) {
        if let builtIn = PresetCatalog.builtIn(named: name) {
            apply(builtIn.layout())
            return
        }
        do {
            let user = try LayoutStore.shared.loadUserPreset(name: name)
            apply(user)
        } catch {
            ErrorLog.log("LayoutStore.loadUserPreset failed for name '\(name)'",
                         error: error,
                         class: String(describing: Self.self))
        }
    }

    public func saveCurrentLayout(name: String) {
        do {
            try LayoutStore.shared.saveUserPreset(name: name, layout: layout)
        } catch {
            ErrorLog.log("LayoutStore.saveUserPreset failed for name '\(name)'",
                         error: error,
                         class: String(describing: Self.self))
        }
    }

    /// Toggle the active preset's "Reset" — reload the active preset from disk
    /// (or from built-ins) discarding any unsaved user moves. Spec §10 ⌃⌘0.
    public func resetToActivePreset() {
        applyPreset(layout.activePreset.isEmpty ? BuiltInPreset.browser.rawValue : layout.activePreset)
    }

    /// Float-or-dock the active panel — toggles between floating and the
    /// last docked position. Spec §10 ⌃⌘F.
    public func toggleFloat(_ id: String) {
        guard let descriptor = BuiltInPanelCatalog.descriptor(for: id),
              descriptor.supportsFloating else { return }
        if layout.position(of: id) == .floating {
            // Move back to its built-in default docked position.
            movePanel(id, to: descriptor.defaultPosition == .floating ? .right : descriptor.defaultPosition)
        } else {
            movePanel(id, to: .floating)
        }
    }

    // MARK: - Apply (persists to disk)

    private func apply(_ new: PanelLayout) {
        guard new != layout else { return }
        let _trace = PerformanceLog.shared.start("Panel.LayoutApply",
            extra: [("preset", new.activePreset)])
        defer { _trace.finish() }
        self.layout = new
        // Persist; if persistence fails (e.g., schema violation), we still
        // publish the new in-memory state so the user can recover.
        do {
            try LayoutStore.shared.save(new)
        } catch {
            ErrorLog.log("LayoutStore.save failed — layout persistence",
                         error: error,
                         class: String(describing: Self.self))
            NSLog("ImageGlass: failed to persist layout: \(error)")
        }
        // Human-readable YAML mirror at
        // `~/Library/Application Support/ImageGlass_Mac/panels.yaml`.
        // The contract from project CLAUDE.md is that the user-visible
        // settings file remembers "which panels are open and where" —
        // this is that file. Failure is non-fatal: the JSON store above
        // already has the authoritative copy.
        do {
            try PanelStateYAMLStore.shared.save(new)
        } catch {
            ErrorLog.log("PanelStateYAMLStore.save failed — panels.yaml mirror",
                         error: error,
                         class: String(describing: Self.self))
        }
    }
}
