import Foundation
import SwiftUI
import Observation
import ImageGlassCore

/// Main-actor controller that ties the headless `PanelRegistry` to live
/// SwiftUI state. This is the type the panel host observes for re-renders.
///
/// Responsibilities:
///   - Bootstrap (load `layout.json`, register built-in descriptors, apply
///     the active preset to the registry).
///   - Provide a `@Observable` snapshot the SwiftUI host reads.
///   - Persist changes back to disk with a 200 ms debounce (spec §3.4).
///   - Expose the MCP-compatible verbs `show / hide / move / float /
///     applyPreset` that mutate both the registry and the on-disk document.
@MainActor
@Observable
public final class LayoutController {

    /// Current snapshot of state for every registered panel, keyed by id.
    public private(set) var statesById: [String: PanelInstanceState] = [:]

    /// All registered descriptors in registration order.
    public private(set) var descriptorsInOrder: [PanelDescriptor] = []

    /// Currently active preset (mirror of `LayoutDocument.activePresetId`).
    public private(set) var activePresetId: String = LayoutPreset.browser.id

    /// The live document. Mutated through `applyPreset`, `show`, `hide`,
    /// etc.; persisted to disk by `scheduleSave()`.
    public private(set) var document: LayoutDocument = .initial

    private let registry: PanelRegistry
    private let store: LayoutStore
    private var saveWorkItem: DispatchWorkItem?

    /// Debounce window for layout persistence — spec §3.4 says 200 ms.
    public var saveDebounceMs: Int = 200

    public init(
        registry: PanelRegistry = .shared,
        store: LayoutStore = .shared
    ) {
        self.registry = registry
        self.store = store
    }

    // MARK: - Bootstrap

    /// Loads `layout.json` (creating it on first run), registers the
    /// built-in panel descriptors, applies the active preset.
    public func bootstrap(builtinDescriptors: [PanelDescriptor]) async {
        // 1. Load the document.
        let doc: LayoutDocument
        do {
            doc = try store.load()
        } catch {
            NSLog("LayoutController: failed to load layout.json, using defaults: \(error)")
            doc = LayoutDocument.initial
        }
        self.document = doc
        self.activePresetId = doc.activePresetId

        // 2. Register every built-in descriptor.
        for d in builtinDescriptors {
            do {
                try await registry.register(d)
            } catch PanelRegistryError.duplicateId {
                // benign on hot reload
            } catch {
                NSLog("LayoutController: register \(d.id) failed: \(error)")
            }
        }

        // 3. Apply the active preset onto the registry.
        await applyActivePreset()

        // 4. Pull the resulting snapshot into our @Observable mirror.
        await refreshSnapshot()
    }

    // MARK: - Snapshot

    public func refreshSnapshot() async {
        let descriptors = await registry.all()
        let states = await registry.allStates()
        self.descriptorsInOrder = descriptors
        var byId: [String: PanelInstanceState] = [:]
        for s in states { byId[s.id] = s }
        self.statesById = byId
    }

    // MARK: - Preset application

    public func applyActivePreset() async {
        let active = document.activePreset
        let registered = Set((await registry.all()).map(\.id))
        let targetStates = LayoutDirector.instanceStates(
            for: active,
            registered: registered
        )
        for state in targetStates {
            do { try await registry.updateState(id: state.id, state) }
            catch { NSLog("LayoutController: updateState(\(state.id)) failed: \(error)") }
        }
        await refreshSnapshot()
    }

    /// Switches to a preset by name or id. Returns true on success.
    @discardableResult
    public func applyPreset(named name: String) async -> Bool {
        guard let preset = document.preset(named: name) else { return false }
        document.activePresetId = preset.id
        activePresetId = preset.id
        await applyActivePreset()
        scheduleSave()
        return true
    }

    // MARK: - MCP verbs

    @discardableResult
    public func show(id: String, at position: PanelPosition? = nil) async -> PanelInstanceState? {
        do {
            let state = try await registry.show(id: id, at: position)
            await refreshSnapshot()
            scheduleSave()
            return state
        } catch {
            NSLog("LayoutController.show(\(id)) failed: \(error)")
            return nil
        }
    }

    @discardableResult
    public func hide(id: String) async -> Bool {
        do {
            _ = try await registry.hide(id: id)
            await refreshSnapshot()
            scheduleSave()
            return true
        } catch {
            NSLog("LayoutController.hide(\(id)) failed: \(error)")
            return false
        }
    }

    @discardableResult
    public func float(id: String, frame: CGRect? = nil) async -> Bool {
        do {
            _ = try await registry.float(id: id, frame: frame)
            await refreshSnapshot()
            scheduleSave()
            return true
        } catch {
            NSLog("LayoutController.float(\(id)) failed: \(error)")
            return false
        }
    }

    /// Persists a divider-drag size change into the active preset's
    /// `windows[0]` zone and schedules a save. Floating/hidden positions
    /// are no-ops.
    public func setZoneSize(at position: PanelPosition, to size: Double) {
        let active = activePresetId
        if let idx = document.presets.firstIndex(where: { $0.id == active }) {
            applyZoneSize(at: position, to: size, presetIndex: idx, isUser: false)
        } else if let idx = document.userPresets.firstIndex(where: { $0.id == active }) {
            applyZoneSize(at: position, to: size, presetIndex: idx, isUser: true)
        }
        scheduleSave()
    }

    private func applyZoneSize(
        at position: PanelPosition,
        to size: Double,
        presetIndex: Int,
        isUser: Bool
    ) {
        var preset = isUser ? document.userPresets[presetIndex] : document.presets[presetIndex]
        guard !preset.windows.isEmpty else { return }
        var window = preset.windows[0]
        switch position {
        case .left:   window.zones.left.size   = size
        case .right:  window.zones.right.size  = size
        case .top:    window.zones.top.size    = size
        case .bottom: window.zones.bottom.size = size
        case .floating, .hidden: return
        }
        preset.windows[0] = window
        if isUser {
            document.userPresets[presetIndex] = preset
        } else {
            document.presets[presetIndex] = preset
        }
    }

    // MARK: - Persistence (debounced)

    /// Schedules a write to `layout.json`. Coalesces rapid mutations.
    public func scheduleSave() {
        saveWorkItem?.cancel()
        let doc = document
        let store = self.store
        let work = DispatchWorkItem {
            do { try store.save(doc) }
            catch { NSLog("LayoutController: save failed: \(error)") }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(saveDebounceMs),
            execute: work
        )
    }

    /// Flushes any pending debounced save immediately. Used at app quit.
    public func flushPendingSave() {
        if let work = saveWorkItem {
            work.cancel()
            saveWorkItem = nil
            do { try store.save(document) }
            catch { NSLog("LayoutController: flush save failed: \(error)") }
        }
    }

    // MARK: - Query helpers used by the host view

    /// All panels currently docked at a given zone, in their authored order.
    public func dockedPanels(at position: PanelPosition) -> [PanelDescriptor] {
        guard position.isDocked else { return [] }
        // Use the preset's slot order so the UI matches what the user authored,
        // falling back to descriptor order for ad-hoc panels.
        let active = document.activePreset
        let slotOrder: [String]
        switch position {
        case .left:   slotOrder = active.windows.first?.zones.left.panels.map(\.id) ?? []
        case .right:  slotOrder = active.windows.first?.zones.right.panels.map(\.id) ?? []
        case .top:    slotOrder = active.windows.first?.zones.top.panels.map(\.id) ?? []
        case .bottom: slotOrder = active.windows.first?.zones.bottom.panels.map(\.id) ?? []
        default:      slotOrder = []
        }
        let liveIds = Set(statesById.values
            .filter { $0.visible && $0.position == position }
            .map(\.id))
        var seen = Set<String>()
        var result: [PanelDescriptor] = []
        // Authored order first…
        for id in slotOrder where liveIds.contains(id) {
            if let d = descriptorsInOrder.first(where: { $0.id == id }) {
                result.append(d); seen.insert(id)
            }
        }
        // …then any panel docked here but not authored into the preset.
        for d in descriptorsInOrder where liveIds.contains(d.id) && !seen.contains(d.id) {
            result.append(d); seen.insert(d.id)
        }
        return result
    }

    /// All panels currently floating.
    public func floatingPanels() -> [PanelDescriptor] {
        descriptorsInOrder.filter { statesById[$0.id]?.position == .floating }
    }
}
