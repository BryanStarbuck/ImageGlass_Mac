import Foundation

/// Pure selection-state operations on top of an ordered file list.
/// Implements the selection rules in spec §4.3 — click / shift-click /
/// cmd-click / select-all / clear.
///
/// The view model holds a `Set<URL-as-String>` of selected paths and a
/// `focusedItem` (the most recent click anchor). All operations here take and
/// return new state, so they are trivial to test.
public struct FileListSelectionState: Equatable, Sendable {
    /// Currently selected paths.
    public var selected: Set<String>
    /// Last-clicked item — anchor for shift-range and arrow nav.
    public var focused: String?

    public init(selected: Set<String> = [], focused: String? = nil) {
        self.selected = selected
        self.focused = focused
    }

    public static let empty = FileListSelectionState()
}

public enum FileListSelectionAction: Sendable {
    /// Plain click. Replaces selection with the single item, sets focus.
    case click(String)
    /// Shift+click. Extends selection from focused → clicked (inclusive).
    case shiftClick(String)
    /// Cmd+click. Toggles a single item in/out of selection. Sets focus.
    case cmdClick(String)
    /// Cmd+A. Selects every item currently in the visible list.
    case selectAll
    /// Esc. Clears the selection (focus survives).
    case clear
    /// Arrow nav — move focus by N items, optionally extending selection.
    case moveFocus(offset: Int, extending: Bool)
    /// Replace selection entirely (used by MCP `select_files`).
    case setMany([String])
}

public enum FileListSelection {

    /// Apply an action against the current state, given the current visible
    /// list of file paths. Pure — caller persists the new state.
    public static func apply(
        _ action: FileListSelectionAction,
        to state: FileListSelectionState,
        visible: [String]
    ) -> FileListSelectionState {
        switch action {
        case .click(let path):
            return .init(selected: [path], focused: path)

        case .shiftClick(let path):
            guard let anchor = state.focused ?? state.selected.first,
                  let a = visible.firstIndex(of: anchor),
                  let b = visible.firstIndex(of: path)
            else {
                return .init(selected: [path], focused: path)
            }
            let lo = min(a, b), hi = max(a, b)
            let range = Array(visible[lo...hi])
            return .init(selected: Set(range), focused: path)

        case .cmdClick(let path):
            var sel = state.selected
            if sel.contains(path) { sel.remove(path) } else { sel.insert(path) }
            return .init(selected: sel, focused: path)

        case .selectAll:
            return .init(selected: Set(visible), focused: state.focused ?? visible.first)

        case .clear:
            return .init(selected: [], focused: state.focused)

        case .moveFocus(let offset, let extending):
            guard !visible.isEmpty else { return state }
            let cur = state.focused.flatMap { visible.firstIndex(of: $0) } ?? -1
            let target = clampToIndex(cur + offset, count: visible.count)
            let newFocus = visible[target]
            if extending {
                let anchor = state.focused ?? newFocus
                guard let a = visible.firstIndex(of: anchor) else {
                    return .init(selected: [newFocus], focused: newFocus)
                }
                let lo = min(a, target), hi = max(a, target)
                return .init(selected: Set(visible[lo...hi]), focused: newFocus)
            } else {
                return .init(selected: [newFocus], focused: newFocus)
            }

        case .setMany(let paths):
            let inVisible = paths.filter { visible.contains($0) }
            return .init(
                selected: Set(inVisible),
                focused: inVisible.last ?? state.focused
            )
        }
    }

    @inline(__always)
    private static func clampToIndex(_ i: Int, count: Int) -> Int {
        if count <= 0 { return 0 }
        if i < 0 { return 0 }
        if i >= count { return count - 1 }
        return i
    }
}

// MARK: - Invariants for tests

extension FileListSelectionState {
    /// True when every selected path also appears in `visible`. Used by tests
    /// to assert the spec's invariant that selection is a subset of the
    /// currently-visible list.
    public func isSubset(of visible: [String]) -> Bool {
        let v = Set(visible)
        return selected.isSubset(of: v)
    }

    /// True when focused (if non-nil) is selected, or when nothing is selected.
    /// Spec §4.3 — clicking sets focus AND selection to the same item.
    public func focusIsConsistent() -> Bool {
        guard let f = focused else { return true }
        // Focus may legitimately exist without selection (e.g. after Esc).
        if selected.isEmpty { return true }
        return selected.contains(f)
    }
}
