import Foundation
import SwiftUI
import ImageGlassCore

/// Runtime registry of all live `ImageGlassPanel` instances. Spec §8.2.
///
/// Built-in panels register at app launch (`registerBuiltInPanels()`).
/// Plugin panels can register/unregister at any time; the MCP server reads
/// this registry to answer `list_panels`.
@MainActor
public final class PanelRegistry {
    public static let shared = PanelRegistry()

    private var byID: [String: any ImageGlassPanel] = [:]
    private var orderedIDs: [String] = []

    public var registered: [any ImageGlassPanel] {
        orderedIDs.compactMap { byID[$0] }
    }

    public func register(_ panel: any ImageGlassPanel) {
        let id = panel.descriptor.id
        if byID[id] == nil {
            orderedIDs.append(id)
        }
        byID[id] = panel
    }

    public func unregister(id: String) {
        byID.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }
    }

    public func panel(for id: String) -> (any ImageGlassPanel)? {
        byID[id]
    }

    public func descriptors() -> [PanelDescriptor] {
        registered.map { $0.descriptor }
    }
}
