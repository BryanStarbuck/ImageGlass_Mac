import Foundation

/// docs/list_of_files.mdx §3D — user-selectable rendering technology for
/// the file tree. The walker's `RootDirectory` graph is unchanged; only
/// the SwiftUI view that hosts the tree differs.
///
/// `.swiftUI` is the default per §3D.3 — lowest-friction path on a
/// fresh install. The setting persists in `UserDefaults`.
public enum TreeRenderTechnology: String, CaseIterable, Codable, Sendable {
    /// `NSOutlineView` inside `NSScrollView`, bridged into SwiftUI via
    /// `NSViewRepresentable`. Closest match to native macOS feel.
    case appKit = "appkit"

    /// SwiftUI `OutlineGroup` inside `List`. Modern declarative path.
    case swiftUI = "swiftui"

    /// AppKit/SwiftUI configured to mimic Catalyst's UIKit look (§3D.7).
    /// Not a true Catalyst build — purely a stylistic alternative.
    case catalyst = "catalyst"

    public var displayName: String {
        switch self {
        case .appKit:   return "AppKit"
        case .swiftUI:  return "SwiftUI"
        case .catalyst: return "Catalyst"
        }
    }

    public var menuTitle: String {
        switch self {
        case .appKit:   return "AppKit  (NSOutlineView)"
        case .swiftUI:  return "SwiftUI (OutlineGroup)"
        case .catalyst: return "Catalyst (UIKit-styled)"
        }
    }

    static let userDefaultsKey = "ig.tree_render_tech"

    /// One-time migration flag. Early builds defaulted to `.swiftUI`, which
    /// blanks on large trees. Anyone who launched such a build has `swiftui`
    /// persisted. On first launch of a migrated build, rewrite that stale
    /// default to `.appKit`. A user who later picks SwiftUI from the menu is
    /// respected — the flag is already set, so we never touch their choice again.
    static let migratedKey = "ig.tree_render_tech.migrated_v1"

    static func loadOrDefault() -> TreeRenderTechnology {
        if !UserDefaults.standard.bool(forKey: migratedKey) {
            UserDefaults.standard.set(true, forKey: migratedKey)
            if UserDefaults.standard.string(forKey: userDefaultsKey) == TreeRenderTechnology.swiftUI.rawValue {
                UserDefaults.standard.set(TreeRenderTechnology.appKit.rawValue, forKey: userDefaultsKey)
            }
        }
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey)
        if let raw, let tech = TreeRenderTechnology(rawValue: raw) {
            return tech
        }
        // §3D.3 — first launch writes the default back so subsequent
        // launches read a stable value.
        //
        // Default is AppKit (`NSOutlineView`): the SwiftUI `OutlineGroup`/`List`
        // path blanks and stutters on large trees (hundreds of files across
        // many source dirs), which is exactly this fork's workload. AppKit
        // renders children lazily via `child(index:)`, so it scales.
        let fallback = TreeRenderTechnology.appKit
        UserDefaults.standard.set(fallback.rawValue, forKey: userDefaultsKey)
        return fallback
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: TreeRenderTechnology.userDefaultsKey)
    }
}
