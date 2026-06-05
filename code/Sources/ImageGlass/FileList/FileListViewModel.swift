import Foundation
import Observation
import ImageGlassCore

/// @Observable view model for the File List panel.
/// Spec §7.6 — single source of truth that SwiftUI views observe and that
/// the MCP server's controller forwards to.
@MainActor
@Observable
public final class FileListViewModel {

    // MARK: - Inputs (from AppState / Scope)

    /// Display name of the active scope. Used by the toolbar's leftmost label.
    public var activeScopeName: String = ""

    /// Tilde-expanded source directories from the active scope's IncludeRules.
    /// Used by the tree builder so it can group files by source.
    public var sourceDirectories: [String] = []

    /// Raw file list from the scope evaluator. Strings may contain `~`.
    public var resolvedPaths: [String] = [] {
        didSet {
            rebuildEntries()
        }
    }

    // MARK: - View state

    /// Persisted per panel instance (spec §2). Default Strip — Casual Viewer.
    public var viewMode: FileListViewMode = .strip {
        didSet {
            onViewModeChanged?(viewMode)
        }
    }

    public var thumbSize: FileListThumbSize = .medium

    public var sortDescriptor: FileListSortDescriptor = .default {
        didSet { rebuildVisible() }
    }

    public var filterText: String = "" {
        didSet { rebuildVisible() }
    }

    /// Selection state — replaces a raw Set<URL> so the spec's selection
    /// invariants (§4.3) can be tested in isolation. Internal mutators only.
    public private(set) var selectionState: FileListSelectionState = .empty

    /// True if this panel instance drives the main viewer canvas. Spec §4.3.
    public var isPrimary: Bool = true

    /// Hook fired when a user click should load the file into the main viewer.
    /// The Coordinator that owns the viewer sets this.
    public var onLoadInViewer: ((String) -> Void)?

    /// Hook fired when the user (or MCP) changes the view mode. Used for
    /// per-panel persistence.
    public var onViewModeChanged: ((FileListViewMode) -> Void)?

    /// Hook fired when the user (or MCP) changes the selection. Used by MCP
    /// SSE events (`selection.changed`, spec §8.3).
    public var onSelectionChanged: ((FileListSelectionState) -> Void)?

    // MARK: - Derived state

    /// All entries derived from resolvedPaths, in original order, with source
    /// indices assigned.
    public private(set) var entries: [FileEntry] = []

    /// Currently visible (sorted + filtered) entries.
    public private(set) var visibleEntries: [FileEntry] = []

    public var visiblePaths: [String] { visibleEntries.map(\.path) }

    public init() {}

    // MARK: - View-state mutators

    public func setViewMode(_ mode: FileListViewMode) {
        viewMode = mode
    }

    public func setThumbSize(_ size: FileListThumbSize) {
        thumbSize = size
    }

    public func setSort(field: FileListSortField, direction: FileListSortDirection) {
        sortDescriptor = FileListSortDescriptor(
            field: field,
            direction: direction,
            randomSeed: sortDescriptor.randomSeed
        )
    }

    public func setFilter(_ text: String) {
        filterText = text
    }

    // MARK: - Selection mutators

    public func click(_ path: String, loadInViewer: Bool = true) {
        applySelection(.click(path))
        if loadInViewer && isPrimary {
            onLoadInViewer?(path)
        }
    }

    public func shiftClick(_ path: String) {
        applySelection(.shiftClick(path))
    }

    public func cmdClick(_ path: String) {
        applySelection(.cmdClick(path))
    }

    public func selectAll() {
        applySelection(.selectAll)
    }

    public func clearSelection() {
        applySelection(.clear)
    }

    public func moveFocus(by offset: Int, extending: Bool = false) {
        applySelection(.moveFocus(offset: offset, extending: extending))
    }

    /// Used by MCP `select_files`.
    public func setSelection(paths: [String]) {
        applySelection(.setMany(paths))
    }

    private func applySelection(_ action: FileListSelectionAction) {
        let next = FileListSelection.apply(action, to: selectionState, visible: visiblePaths)
        selectionState = next
        onSelectionChanged?(next)
    }

    // MARK: - Bind to AppState

    /// Re-bind from a fresh resolved file list. Computes sourceIndex per
    /// entry based on which directory it falls under. This is the entry
    /// point AppState calls when a scope is loaded or re-evaluated.
    public func update(
        scopeName: String,
        sourceDirectories: [String],
        resolvedPaths: [String]
    ) {
        self.activeScopeName = scopeName
        self.sourceDirectories = sourceDirectories.map(FileListTreeBuilder.normalize)
        self.resolvedPaths = resolvedPaths
    }

    // MARK: - Tree

    /// Cached Tree-mode result. `buildTree()` is called from
    /// `FileListTreeView.body`, i.e. on every redraw — re-walking the whole
    /// visible set each time stutters with hundreds of files. The tree only
    /// depends on `visibleEntries` + `sourceDirectories`, both of which funnel
    /// through `rebuildVisible()`/`update()`, so invalidate there.
    @ObservationIgnored private var cachedTree: [FileListTreeNode]?

    /// Rebuild a per-source tree for Tree mode. Spec §2.5. Cached — see above.
    public func buildTree() -> [FileListTreeNode] {
        if let cachedTree { return cachedTree }
        let tree = FileListTreeBuilder.build(
            entries: visibleEntries,
            sourceDirectories: sourceDirectories
        )
        cachedTree = tree
        return tree
    }

    // MARK: - Private

    private func rebuildEntries() {
        let dirs = sourceDirectories
        var out: [FileEntry] = []
        out.reserveCapacity(resolvedPaths.count)
        for path in resolvedPaths {
            let (idx, dir) = sourceIndex(for: path, in: dirs)
            var entry = FileEntry(path: path, sourceIndex: idx, sourceDirectory: dir)
            // Cheap metadata pre-load is best-effort and skipped for the
            // initial pass — it's loaded lazily by sort/filter on demand.
            entry.loadCheapMetadata()
            out.append(entry)
        }
        entries = out
        rebuildVisible()
    }

    private func rebuildVisible() {
        cachedTree = nil   // visible set is changing — drop the Tree-mode cache.
        let sorted = FileListSorter.sort(entries, by: sortDescriptor)
        let filtered = FileListSorter.filter(sorted, text: filterText)
        visibleEntries = filtered
        // After visible-set changes, prune selection to the new visible set.
        let visibleSet = Set(filtered.map(\.path))
        let pruned = selectionState.selected.intersection(visibleSet)
        if pruned != selectionState.selected {
            selectionState = FileListSelectionState(
                selected: pruned,
                focused: selectionState.focused.flatMap { visibleSet.contains($0) ? $0 : nil }
            )
        }
    }

    private func sourceIndex(for path: String, in dirs: [String]) -> (Int, String) {
        let expanded = AppPaths.expandTilde(path)
        for (i, dir) in dirs.enumerated() {
            if expanded.hasPrefix(dir + "/") || expanded == dir {
                return (i, dir)
            }
        }
        return (0, dirs.first ?? "")
    }
}
