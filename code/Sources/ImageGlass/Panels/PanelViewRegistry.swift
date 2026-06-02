import SwiftUI
import ImageGlassCore

/// Main-actor companion to `PanelRegistry`.
///
/// `PanelRegistry` (in `ImageGlassCore`) holds the SwiftUI-free metadata and
/// runtime state. This type holds the actual view factories — anything that
/// has to return SwiftUI views must live in the `ImageGlass` target because
/// `ImageGlassCore` deliberately stays SwiftUI-free.
///
/// Other panels (file list, crop, themes, …) are owned by other agents.
/// They each call `register(...)` from their bring-up code. The framework
/// itself only ships the descriptor + factory for the initial panel —
/// `directory_filename` — so the existing UX keeps rendering.
@MainActor
public final class PanelViewRegistry {

    public static let shared = PanelViewRegistry()

    private var factories: [String: () -> AnyView] = [:]

    public init() {}

    /// Registers a SwiftUI view factory for a panel id. Idempotent.
    /// Replaces any previous factory under the same id (so plugins can
    /// override built-ins explicitly).
    public func register(id: String, _ make: @escaping () -> AnyView) {
        factories[id] = make
    }

    public func unregister(id: String) {
        factories.removeValue(forKey: id)
    }

    public func makeView(for id: String) -> AnyView? {
        factories[id]?()
    }

    public func hasView(for id: String) -> Bool {
        factories[id] != nil
    }

    public func reset() {
        factories.removeAll()
    }
}
