import SwiftUI
import ImageGlassCore

/// docs/use_cases/include_checks.mdx §2 — the small square swatch at
/// the leftmost edge of every row in the directory / filename panel.
/// Renders one of the four variants from §2.2 and accepts a click to
/// cycle through `Include → Inherit → Don't Include` (§3) for sub-rows
/// or `Include ↔ Don't Include` (§1.0 / §3 header) for roots.
struct IncludeColumnSwatch: View {
    /// include_checks.mdx §2.1 / §2.4 — the swatch is sized against
    /// the **file image icon**, not the row height, so the include
    /// column never adds vertical padding to the file tree. The file
    /// icon renders at SF Symbol point size 13 pt (see
    /// `DesignTreeNode.row(...)`).
    static let fileIconReferenceHeight: CGFloat = 13

    /// §2.4 — the glyph is 80% of the file icon's reference height.
    static var glyphPointSize: CGFloat { fileIconReferenceHeight * 0.80 }

    /// §2.1 — the swatch's outer square equals the file icon's height
    /// so the glyph fills the swatch the same way the file icon fills
    /// its own bounding box.
    static var swatchSide: CGFloat { fileIconReferenceHeight }

    /// Absolute path of the row (file or folder) the swatch belongs
    /// to. Maps to a `RootDirectory` + relative-path via the matching
    /// walker root.
    let absolutePath: String
    /// The walker root the row belongs to. Carries
    /// `defaultIncludeState` and `includeOverrides`.
    let root: RootDirectory
    /// include_checks.mdx §1.0 — true when this swatch is on the root
    /// row itself. Roots cycle through two states only; the swatch
    /// renders only the two saturated variants (1) / (2).
    let isRoot: Bool
    /// Callback invoked when the swatch is clicked. The parent owns
    /// the persistence + audit log via
    /// `IncludeStateController.cycle(...)`.
    let onCycle: (IncludeState) -> Void

    var body: some View {
        let relativePath = IncludePath.relative(absolutePath: absolutePath, root: root.path)
        // §1.0 / §5.2 — for a root row the explicit state lives in
        // `defaultIncludeState`, not the include_overrides[] map. Without this
        // branch the swatch would render the muted "inherit" variant on a
        // freshly-added root, contradicting the two-state cycle.
        let decision: EffectiveIncludeDecision = {
            if isRoot {
                let state: IncludeState = root.defaultIncludeState == .inherit
                    ? .include
                    : root.defaultIncludeState
                return EffectiveIncludeDecision(explicit: state, resolved: state)
            }
            return root.decision(for: relativePath)
        }()
        // §2.5 — Button form. A view-level `.onTapGesture` is
        // swallowed by the parent row's tap gesture in the file
        // panel; `Button` registers through AppKit's hit-test path
        // and reliably wins. Do not regress this.
        Button {
            // §3 — cycle the explicit state. Sub-rows step through
            // three states via `IncludeState.next`; roots flip
            // between two via `nextForRoot` (§1.0).
            let current = decision.explicit
            let next = isRoot ? current.nextForRoot : current.next
            onCycle(next)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(backgroundFill(for: decision))
                Image(systemName: decision.resolved == .include ? "checkmark" : "xmark")
                    .font(.system(size: Self.glyphPointSize, weight: .semibold))
                    .foregroundStyle(glyphColor(for: decision))
            }
            .frame(width: Self.swatchSide, height: Self.swatchSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // §2.5 — pointing-hand cursor flags the swatch as a hit
            // target. Matches the existing folder-row disclosure
            // behavior.
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityLabel(accessibilityLabel(for: decision))
        .accessibilityHint(
            isRoot
                ? "Click to toggle: include, don't include."
                : "Click to cycle: include, inherit, don't include."
        )
        .accessibilityValue((absolutePath as NSString).lastPathComponent)
    }

    /// §2.2 — background-fill mapping for each of the four variants.
    private func backgroundFill(for d: EffectiveIncludeDecision) -> Color {
        switch (d.explicit, d.resolved) {
        case (.include, _):         return IG.includeGreenC
        case (.exclude, _):         return IG.excludeRedC
        case (.inherit, .include):  return IG.inheritIncludeBgC
        case (.inherit, .exclude):  return IG.inheritExcludeBgC
        default:                    return IG.inheritIncludeBgC
        }
    }

    /// §2.2 — glyph color mapping. Explicit decisions are white on a
    /// saturated background; inherits flip back to the saturated
    /// polarity color on top of muted gray.
    private func glyphColor(for d: EffectiveIncludeDecision) -> Color {
        switch (d.explicit, d.resolved) {
        case (.include, _):         return .white
        case (.exclude, _):         return .white
        case (.inherit, .include):  return IG.includeGreenC
        case (.inherit, .exclude):  return IG.excludeRedC
        default:                    return IG.includeGreenC
        }
    }

    /// §2.6 — the resolved state is what VoiceOver speaks.
    private func accessibilityLabel(for d: EffectiveIncludeDecision) -> String {
        switch (d.explicit, d.resolved) {
        case (.include, _):         return "Include"
        case (.exclude, _):         return "Don't include"
        case (.inherit, .include):  return "Inherit (currently include)"
        case (.inherit, .exclude):  return "Inherit (currently don't include)"
        default:                    return "Inherit (currently include)"
        }
    }
}

/// docs/use_cases/include_checks.mdx — shared cycle / set / get
/// helpers used by the swatch click (§3), the `I` hotkey (§4), the
/// menu items (§7), and the MCP tools (§11). All four surfaces route
/// through these helpers so the audit log and the on-disk YAML stay
/// in lockstep.
@MainActor
enum IncludeStateController {
    /// Resolve the walker root for an absolute path. Returns nil
    /// when no registered root contains the path.
    static func root(for absolutePath: String, in roots: [RootDirectory]) -> RootDirectory? {
        // Pick the longest matching root path so nested registrations
        // (`~/Pictures` and `~/Pictures/tour`) prefer the deepest one.
        return roots
            .filter { absolutePath == $0.path.path || absolutePath.hasPrefix($0.path.path + "/") }
            .max(by: { $0.path.path.count < $1.path.path.count })
    }

    /// True when `absolutePath` *is* a registered root in `roots`.
    /// Used by the swatch and the `I`-key handler to route through
    /// the root-level `default_include_state` path rather than the
    /// per-row `include_overrides[]` path (include_checks.mdx §1.0).
    static func isRoot(absolutePath: String, in roots: [RootDirectory]) -> Bool {
        roots.contains { $0.path.path == absolutePath }
    }

    /// Apply a state change driven by the GUI (swatch click, `I`
    /// hotkey, menu item). Writes through `DirectoriesStore`,
    /// journals one `tool=panel.set_include_state` line, and triggers
    /// the cross-process refresh so the headless MCP server picks up
    /// the change. After the YAML write, calls
    /// `appState.refreshWalkerRoots()` so the panel re-renders in the
    /// next frame — per include_checks.mdx §5.6 the in-memory mirror
    /// must update synchronously, not wait for the file watcher.
    @discardableResult
    static func setState(
        absolutePath: String,
        state: IncludeState,
        appState: AppState
    ) -> Bool {
        let roots = appState.walkerRoots
        guard let root = root(for: absolutePath, in: roots) else { return false }
        let corr = MCPAuditLogger.newCorrelationId()
        do {
            let isRootRow = isRoot(absolutePath: absolutePath, in: roots)
            let resolved: IncludeState
            if isRootRow {
                // include_checks.mdx §1.0 / §5.2 — the root's state
                // lives in `default_include_state`. `inherit` is
                // never written for a root.
                let effective = state == .inherit ? IncludeState.include : state
                try DirectoriesStore.shared.setDefaultIncludeState(
                    rootPath: root.path, state: effective
                )
                resolved = effective
            } else {
                let relative = IncludePath.relative(
                    absolutePath: absolutePath, root: root.path
                )
                resolved = try DirectoriesStore.shared.setIncludeState(
                    rootPath: root.path,
                    relativePath: relative,
                    state: state
                )
            }
            MCPAuditLogger.shared.log([
                ("tool", "panel.set_include_state"),
                ("root", root.path.path),
                ("path", isRootRow
                    ? ""
                    : IncludePath.relative(absolutePath: absolutePath, root: root.path)),
                ("state", state.rawValue),
                ("resolved", resolved.rawValue),
                ("client", "gui"),
                ("corr", corr),
                ("ok", "true"),
            ])
            // §5.6 — synchronous in-memory mirror. Updates
            // `state.walkerRoots` so the swatch re-renders in the
            // next frame, ahead of the cross-process notification.
            appState.refreshWalkerRoots()
            MCPNotificationBus.shared.postDirectoriesChanged()
            return true
        } catch {
            MCPAuditLogger.shared.log([
                ("tool", "panel.set_include_state"),
                ("root", root.path.path),
                ("path", IncludePath.relative(absolutePath: absolutePath, root: root.path)),
                ("state", state.rawValue),
                ("client", "gui"),
                ("corr", corr),
                ("ok", "false"),
                ("err", (error as? DirectoriesStoreError)?.auditCode ?? "unknown"),
            ])
            return false
        }
    }

    /// include_checks.mdx §7.2 — recursively set a node and every
    /// descendant to `state` (the "Include On / Off (including children)"
    /// context-menu items, right_click.mdx §7.1 / §7.2). Routes through
    /// the batch `DirectoriesStore.setSubtreeIncludeState`, then does one
    /// synchronous mirror refresh + one cross-process notification, so
    /// the whole subtree re-renders in the next frame (§5.6). Works on a
    /// root row too — there "including children" is the entire root
    /// subtree.
    @discardableResult
    static func setSubtree(
        absolutePath: String,
        state: IncludeState,
        appState: AppState
    ) -> Bool {
        let roots = appState.walkerRoots
        guard let root = root(for: absolutePath, in: roots) else { return false }
        let corr = MCPAuditLogger.newCorrelationId()
        let relative = IncludePath.relative(absolutePath: absolutePath, root: root.path)
        do {
            let resolved = try DirectoriesStore.shared.setSubtreeIncludeState(
                rootPath: root.path, relativePath: relative, state: state
            )
            MCPAuditLogger.shared.log([
                ("tool", "panel.set_include_state"),
                ("root", root.path.path),
                ("path", relative),
                ("state", state.rawValue),
                ("resolved", resolved.rawValue),
                ("recursive", "true"),
                ("client", "gui"),
                ("corr", corr),
                ("ok", "true"),
            ])
            appState.refreshWalkerRoots()
            MCPNotificationBus.shared.postDirectoriesChanged()
            return true
        } catch {
            MCPAuditLogger.shared.log([
                ("tool", "panel.set_include_state"),
                ("root", root.path.path),
                ("path", relative),
                ("state", state.rawValue),
                ("recursive", "true"),
                ("client", "gui"),
                ("corr", corr),
                ("ok", "false"),
                ("err", (error as? DirectoriesStoreError)?.auditCode ?? "unknown"),
            ])
            return false
        }
    }

    /// include_checks.mdx §7.3 — switch the **entire tree** (every root
    /// and every node) to `state` (the "Change Include ▸ Change Include
    /// On / Off" folder-menu submenu, right_click.mdx §7.2). One batch
    /// YAML write via `DirectoriesStore.setAllRootsIncludeState`, then one
    /// mirror refresh + one notification.
    @discardableResult
    static func setEntireTree(
        state: IncludeState,
        appState: AppState
    ) -> Bool {
        let corr = MCPAuditLogger.newCorrelationId()
        do {
            let count = try DirectoriesStore.shared.setAllRootsIncludeState(state: state)
            MCPAuditLogger.shared.log([
                ("tool", "panel.set_include_state"),
                ("scope", "entire_tree"),
                ("state", state.rawValue),
                ("roots", String(count)),
                ("client", "gui"),
                ("corr", corr),
                ("ok", "true"),
            ])
            appState.refreshWalkerRoots()
            MCPNotificationBus.shared.postDirectoriesChanged()
            return true
        } catch {
            MCPAuditLogger.shared.log([
                ("tool", "panel.set_include_state"),
                ("scope", "entire_tree"),
                ("state", state.rawValue),
                ("client", "gui"),
                ("corr", corr),
                ("ok", "false"),
                ("err", (error as? DirectoriesStoreError)?.auditCode ?? "unknown"),
            ])
            return false
        }
    }

    /// Cycle the explicit state of the row one step. Sub-rows go
    /// through `Include → Inherit → Don't Include → Include …` per
    /// §3; root rows flip between `Include ↔ Don't Include` per
    /// §1.0. Returns the new explicit state.
    @discardableResult
    static func cycle(
        absolutePath: String,
        appState: AppState
    ) -> IncludeState? {
        let roots = appState.walkerRoots
        guard let root = root(for: absolutePath, in: roots) else { return nil }
        let isRootRow = isRoot(absolutePath: absolutePath, in: roots)
        let current: IncludeState
        if isRootRow {
            // §1.0 — the root's current explicit state is its
            // `defaultIncludeState`, not an `include_overrides[]`
            // entry. An `inherit` value here is a corrupt-YAML case
            // that `nextForRoot` coerces to `.include`.
            current = root.defaultIncludeState
        } else {
            let relative = IncludePath.relative(absolutePath: absolutePath, root: root.path)
            current = root.explicitState(for: relative)
        }
        let next = isRootRow ? current.nextForRoot : current.next
        guard setState(absolutePath: absolutePath, state: next, appState: appState) else {
            return nil
        }
        return next
    }
}
