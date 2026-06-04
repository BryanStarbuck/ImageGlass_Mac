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

    static func loadOrDefault() -> TreeRenderTechnology {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey)
        if let raw, let tech = TreeRenderTechnology(rawValue: raw) {
            return tech
        }
        // §3D.3 — first launch writes the default back so subsequent
        // launches read a stable value.
        let fallback = TreeRenderTechnology.swiftUI
        UserDefaults.standard.set(fallback.rawValue, forKey: userDefaultsKey)
        return fallback
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: TreeRenderTechnology.userDefaultsKey)
    }
}
