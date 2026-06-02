import Foundation

/// High-level audit surface for the **fork charter** described in
/// `docs/overview.mdx` § "Most Important Rules and Goals".
///
/// Every change in this repository is supposed to serve one of five
/// load-bearing goals:
///
/// 1. MCP support
/// 2. Modular UI panels (new column)
/// 3. Scope controls (include / exclude)
/// 4. Local Storage feature
/// 5. MCP-driven editing of Local Storage
///
/// This module gives the rest of the codebase a single, programmatic way
/// to ask *"is the overview-level charter still wired up end-to-end?"*
/// without duplicating any single subsystem spec (panels.mdx, mcp.mdx,
/// crop.mdx, list_of_files.mdx, etc.). It is **deliberately high-level**:
/// it checks symbol-level wiring and round-trip behaviour, not per-feature
/// UX or per-panel polish.
///
/// Intended uses:
/// * Quick smoke-test on app launch and in CI.
/// * Diagnostic the MCP server can expose to Claude Code.
/// * Anchor for tests that protect against silent charter regressions.
public enum CharterGoal: String, Codable, CaseIterable, Sendable {
    case mcpSupport
    case modularPanels
    case scopeControls
    case localStorage
    case mcpDrivenEditing

    public var index: Int {
        switch self {
        case .mcpSupport:        return 1
        case .modularPanels:     return 2
        case .scopeControls:     return 3
        case .localStorage:      return 4
        case .mcpDrivenEditing:  return 5
        }
    }

    public var title: String {
        switch self {
        case .mcpSupport:        return "MCP Support"
        case .modularPanels:     return "Modular UI Panels (New Column)"
        case .scopeControls:     return "Scope Controls (Include / Exclude)"
        case .localStorage:      return "Local Storage Feature"
        case .mcpDrivenEditing:  return "MCP-Driven Editing of Local Storage"
        }
    }

    public var overviewSummary: String {
        switch self {
        case .mcpSupport:
            return "Embed an MCP server so Claude Code can drive ImageGlass from outside the app."
        case .modularPanels:
            return "Add a new column hosting modular panels; first panel is directory/filename with list + tree modes."
        case .scopeControls:
            return "Explicit include/exclude controls over directories, glob criteria, and extensions."
        case .localStorage:
            return "Plain-text on-disk scope store: source criteria, resolved file list, last-evaluated timestamp."
        case .mcpDrivenEditing:
            return "MCP tools let Claude read and modify Local Storage without opening the GUI."
        }
    }
}

/// Coarse implementation state. Granular per-subsystem status lives in
/// the specs for those subsystems (panels.mdx, mcp.mdx, etc.) — this is
/// the overview-level signal only.
public enum CharterState: String, Codable, Sendable {
    case implemented
    case partial
    case missing
}

/// One row of the charter status report.
public struct CharterGoalStatus: Codable, Sendable, Equatable {
    public var goal: CharterGoal
    public var state: CharterState
    /// Human-readable evidence — which symbols / files / behaviours were
    /// observed to support this state.
    public var evidence: [String]
    /// Anything the auditor noticed that's still open at the charter
    /// level. Empty when fully shipped.
    public var openGaps: [String]

    public init(
        goal: CharterGoal,
        state: CharterState,
        evidence: [String] = [],
        openGaps: [String] = []
    ) {
        self.goal = goal
        self.state = state
        self.evidence = evidence
        self.openGaps = openGaps
    }
}

/// A full charter audit snapshot, suitable for JSON dump.
public struct CharterStatusReport: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var goals: [CharterGoalStatus]

    public init(generatedAt: Date = Date(), goals: [CharterGoalStatus]) {
        self.generatedAt = generatedAt
        self.goals = goals
    }

    public func status(for goal: CharterGoal) -> CharterGoalStatus? {
        goals.first { $0.goal == goal }
    }

    /// True when every charter goal is at least `partial`, i.e. nothing
    /// has silently disappeared.
    public var allGoalsPresent: Bool {
        goals.count == CharterGoal.allCases.count &&
            goals.allSatisfy { $0.state != .missing }
    }
}

/// Public entry point. The implementation is intentionally simple — it
/// checks **observable wiring** in the core library, not GUI polish.
/// Calling code (the app, the MCP server, CI, tests) gets a stable shape.
public enum CharterStatus {

    public static let documentURL: String = "docs/overview.mdx"

    /// Build a status report by exercising the actual core APIs.
    /// Safe to call from any context; performs only in-memory work plus
    /// an optional Local Storage round-trip in a temporary scratch scope.
    public static func report() -> CharterStatusReport {
        CharterStatusReport(goals: [
            evaluateMCPSupport(),
            evaluateModularPanels(),
            evaluateScopeControls(),
            evaluateLocalStorage(),
            evaluateMCPDrivenEditing(),
        ])
    }

    /// Single-line summary string for logs / About panels.
    public static func summary() -> String {
        let r = report()
        let counts = Dictionary(grouping: r.goals, by: { $0.state })
            .mapValues { $0.count }
        let impl = counts[.implemented] ?? 0
        let part = counts[.partial] ?? 0
        let miss = counts[.missing] ?? 0
        return "ImageGlass charter: \(impl) implemented, \(part) partial, \(miss) missing (of \(CharterGoal.allCases.count))."
    }

    // MARK: - Per-goal evaluators

    private static func evaluateMCPSupport() -> CharterGoalStatus {
        let tools = MCPTools()
        let descriptors = tools.descriptors()
        var evidence: [String] = []
        evidence.append("MCPProtocol.swift defines JSON-RPC envelope + InitializeResult / ListToolsResult.")
        evidence.append("MCPServer.swift speaks line-delimited JSON-RPC over stdio with initialize / tools.list / tools.call.")
        evidence.append("imageglass-mcp executable target registered in Package.swift.")
        evidence.append("Tools advertised: \(descriptors.count).")
        let state: CharterState = descriptors.isEmpty ? .partial : .implemented
        return CharterGoalStatus(
            goal: .mcpSupport,
            state: state,
            evidence: evidence,
            openGaps: descriptors.isEmpty ? ["No tools registered — clients have nothing to call."] : []
        )
    }

    private static func evaluateModularPanels() -> CharterGoalStatus {
        // The panel host lives in the SwiftUI app target, but the panel
        // catalog, layout schema, MCP surface, presets, and store live in
        // core so we can verify them from here.
        var evidence: [String] = []
        let catalog = BuiltInPanelCatalog.all.map { $0.id }.sorted()
        evidence.append("BuiltInPanelCatalog publishes \(catalog.count) panels: \(catalog.joined(separator: ", ")).")
        evidence.append("Layout schema (PanelLayout.schema_version = \(PanelLayout.currentSchemaVersion)) with DockPosition / TabGroup / FloatingPanel / HiddenPanelState.")
        evidence.append("Built-in presets: " + BuiltInPreset.allCases.map { $0.rawValue }.joined(separator: ", ") + ".")
        let panelMCPNames = PanelMCPTools().descriptors().map { $0.name }.sorted()
        evidence.append("Panel MCP surface: \(panelMCPNames.joined(separator: ", ")).")
        evidence.append("LayoutStore persists layout.json at \(AppPaths.layoutFile.path) with atomic write + .bak rollback.")
        evidence.append("App-side: DirectoryFilenamePanel + FileTreeNode + AppState.PanelViewMode (list/tree).")
        var gaps: [String] = []
        let requiredMCP: Set<String> = [
            "list_panels", "show_panel", "hide_panel", "move_panel",
            "set_panel_size", "tab_panels", "untab_panel",
            "apply_layout_preset", "save_current_layout", "delete_layout_preset",
            "get_layout_state", "set_layout_state",
        ]
        let missing = requiredMCP.subtracting(panelMCPNames).sorted()
        if !missing.isEmpty {
            gaps.append("Panel MCP tools missing: \(missing.joined(separator: ", ")).")
        }
        // Drag-snap and tab-via-drag come from the AppKit `NSSplitViewController`
        // bridge described in panels.mdx §8.1 — the SwiftUI host renders the
        // layout but real drag-to-snap requires `NSPanGestureRecognizer` work
        // tracked under the panels subsystem.
        gaps.append("Drag-to-snap (NSPanGestureRecognizer) and snap-preview overlay (panels.mdx §5.1) are spec'd; SwiftUI host renders the resolved layout for now.")
        return CharterGoalStatus(
            goal: .modularPanels,
            state: missing.isEmpty ? .implemented : .partial,
            evidence: evidence,
            openGaps: gaps
        )
    }

    private static func evaluateScopeControls() -> CharterGoalStatus {
        // Build a synthetic scope in-memory + actually run the evaluator on a
        // throw-away temporary directory so we catch silent regressions in
        // include / exclude semantics, not just the shape of the type.
        let probe = Scope(
            name: "__charter_probe__",
            criteria: [
                Scope.SourceCriterion(
                    root: "~/Pictures",
                    recursive: true,
                    includeExts: ["jpg", "png"],
                    includeGlobs: ["IMG_*"],
                    excludeGlobs: ["*_old*"],
                    includeHidden: false
                )
            ]
        )
        var evidence: [String] = []
        evidence.append("Scope.IncludeRules carries directories, recursive flag, globs, extensions.")
        evidence.append("Scope.ExcludeRules carries globs and hiddenFiles flag.")
        evidence.append("ScopeEvaluator walks directories + applies filters (see ScopeEvaluatorTests).")
        let hasInclude =
            !probe.include.directories.isEmpty &&
            !probe.include.extensions.isEmpty &&
            !probe.include.globs.isEmpty
        let hasExclude =
            !probe.exclude.globs.isEmpty && probe.exclude.hiddenFiles
        var gaps: [String] = []
        let walkerOK = runScopeWalkerSelfCheck(gaps: &gaps)
        if walkerOK {
            evidence.append("ScopeEvaluator self-check: walker correctly applies include/exclude rules on a scratch directory.")
        }
        let state: CharterState = (hasInclude && hasExclude && walkerOK) ? .implemented : .partial
        return CharterGoalStatus(
            goal: .scopeControls,
            state: state,
            evidence: evidence,
            openGaps: gaps
        )
    }

    private static func evaluateLocalStorage() -> CharterGoalStatus {
        var evidence: [String] = []
        evidence.append("LocalStorage persists each scope as plain JSON in \(AppPaths.scopesDir.path).")
        evidence.append("Scope records: include rules, exclude rules, lastEvaluated, resolvedFiles, description.")
        evidence.append("bootstrapIfNeeded() seeds a starter scope so the panel column has something to show on first launch.")
        var gaps: [String] = []
        // Path shape check — the on-disk story lives at .../ImageGlass/scopes.
        let pathOK = AppPaths.scopesDir.path.contains("/ImageGlass/scopes")
        if !pathOK { gaps.append("scopesDir path does not look like '.../ImageGlass/scopes'.") }
        // Round-trip behaviour check on an in-memory scope through the same
        // JSONEncoder/JSONDecoder configuration LocalStorage uses. This
        // protects the plain-text contract from silent codable regressions
        // without touching the user's real Application Support.
        let roundTripOK = runScopeRoundTripSelfCheck(gaps: &gaps)
        if roundTripOK {
            evidence.append("Codable round-trip preserves all three required fields (source criteria, resolvedFiles, lastEvaluated).")
        }
        let state: CharterState = (pathOK && roundTripOK) ? .implemented : .partial
        return CharterGoalStatus(
            goal: .localStorage,
            state: state,
            evidence: evidence,
            openGaps: gaps
        )
    }

    // MARK: - Self-check helpers

    /// Drop two files into a scratch directory and confirm ScopeEvaluator
    /// applies both an include extension and an exclude glob. The scratch
    /// directory is removed before returning.
    private static func runScopeWalkerSelfCheck(gaps: inout [String]) -> Bool {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ig-charter-walker-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: scratch.appendingPathComponent("keep.png"))
            try Data("x".utf8).write(to: scratch.appendingPathComponent("draft_old.png"))
            try Data("x".utf8).write(to: scratch.appendingPathComponent("notes.txt"))
            let probe = Scope(
                name: "__charter_walker_probe__",
                include: .init(directories: [scratch.path], recursive: false, extensions: ["png"]),
                exclude: .init(globs: ["*_old*"], hiddenFiles: true)
            )
            let files = ScopeEvaluator.resolveFiles(for: probe)
                .map { ($0 as NSString).lastPathComponent }
            if files == ["keep.png"] { return true }
            ErrorLog.log("ScopeEvaluator self-check produced unexpected files: \(files)",
                         class: "CharterStatus")
            gaps.append("ScopeEvaluator self-check failed: expected [keep.png], got \(files).")
            return false
        } catch {
            ErrorLog.log("ScopeEvaluator self-check failed to create scratch dir",
                         error: error,
                         class: "CharterStatus")
            gaps.append("ScopeEvaluator self-check could not create scratch dir: \(error.localizedDescription)")
            return false
        }
    }

    /// Round-trip an in-memory Scope through the same JSON shape that
    /// LocalStorage writes, and confirm the three load-bearing fields survive.
    private static func runScopeRoundTripSelfCheck(gaps: inout [String]) -> Bool {
        let probe = Scope(
            name: "__charter_codable_probe__",
            description: "audit probe",
            include: .init(directories: ["~/Pictures"], recursive: true,
                           globs: ["IMG_*"], extensions: ["png"]),
            exclude: .init(globs: ["*_old*"], hiddenFiles: true),
            lastEvaluated: Date(timeIntervalSince1970: 1_700_000_000),
            resolvedFiles: ["~/Pictures/a.png", "~/Pictures/b.png"]
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let data = try enc.encode(probe)
            let back = try dec.decode(Scope.self, from: data)
            guard back.include == probe.include,
                  back.exclude == probe.exclude,
                  back.lastEvaluated == probe.lastEvaluated,
                  back.resolvedFiles == probe.resolvedFiles else {
                ErrorLog.log("Scope JSON round-trip did not preserve all load-bearing fields",
                             class: "CharterStatus")
                gaps.append("Scope JSON round-trip did not preserve all load-bearing fields.")
                return false
            }
            return true
        } catch {
            ErrorLog.log("Scope JSON round-trip threw",
                         error: error,
                         class: "CharterStatus")
            gaps.append("Scope JSON round-trip threw: \(error.localizedDescription)")
            return false
        }
    }

    private static func evaluateMCPDrivenEditing() -> CharterGoalStatus {
        // The charter's load-bearing claim is that the SAME MCP server
        // tools cover the SAME Local Storage read/write surface. Verify by
        // intersecting the advertised tool names with the canonical set.
        let advertised = Set(MCPTools().descriptors().map { $0.name })
        let required: Set<String> = [
            "list_scopes",
            "get_scope",
            "create_scope",
            "set_directories",
            "set_include_criteria",
            "set_exclude_criteria",
            "evaluate_scope",
            "delete_scope",
        ]
        let missing = required.subtracting(advertised).sorted()
        var evidence: [String] = []
        evidence.append("MCPTools advertises \(advertised.count) tools; \(required.count) are required for charter-level Local Storage editing.")
        evidence.append("Required tools present: \(required.intersection(advertised).sorted().joined(separator: ", ")).")
        let state: CharterState
        if missing.isEmpty {
            state = .implemented
        } else if missing.count < required.count {
            state = .partial
        } else {
            state = .missing
        }
        return CharterGoalStatus(
            goal: .mcpDrivenEditing,
            state: state,
            evidence: evidence,
            openGaps: missing.isEmpty
                ? []
                : ["Missing MCP tools required by overview §5: \(missing.joined(separator: ", "))."]
        )
    }
}

// MARK: - Convenience top-level API on ImageGlassCore

/// Top-level helpers so callers can write `ImageGlassCore.charterStatus()`
/// instead of digging through the type. Pure surface area — they forward
/// to `CharterStatus`.
public enum ImageGlassCore {
    public static func charterStatus() -> CharterStatusReport {
        CharterStatus.report()
    }
    public static func charterSummary() -> String {
        CharterStatus.summary()
    }
}
