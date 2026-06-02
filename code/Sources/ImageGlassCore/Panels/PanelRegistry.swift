import Foundation

/// Errors thrown by `PanelRegistry`.
public enum PanelRegistryError: Error, Equatable, CustomStringConvertible {
    case invalidId(String)
    case duplicateId(String)
    case unknownId(String)
    case cannotFloat(String)

    public var description: String {
        switch self {
        case .invalidId(let id):
            return "Panel id '\(id)' does not match ^[a-z][a-z0-9_]{2,63}$."
        case .duplicateId(let id):
            return "Panel id '\(id)' is already registered."
        case .unknownId(let id):
            return "No panel with id '\(id)' is registered."
        case .cannotFloat(let id):
            return "Panel '\(id)' does not support floating."
        }
    }
}

/// Single source of truth for which panels exist, what their static metadata
/// is, and what runtime state each currently has.
///
/// The spec (§5.3) declares this as an `actor` so concurrent MCP callers and
/// the layout director cannot tear it. We honor that here.
///
/// View factories are *not* stored here — they live on the UI side
/// (`PanelViewRegistry` in the `ImageGlass` target). This keeps the core
/// dependency-free of SwiftUI / AppKit, so MCP and the test target can use
/// the same type.
public actor PanelRegistry {

    public static let shared = PanelRegistry()

    private var descriptors: [String: PanelDescriptor] = [:]
    /// Preserved insertion order of registrations — drives default UI ordering.
    private var order: [String] = []
    private var states: [String: PanelInstanceState] = [:]

    public init() {}

    // MARK: - Registration

    /// Registers a panel. Idempotent re-registration (same id, same descriptor)
    /// is allowed and is a no-op; re-registering a different descriptor with
    /// the same id throws `.duplicateId`.
    public func register(_ descriptor: PanelDescriptor) throws {
        guard PanelDescriptor.isValidId(descriptor.id) else {
            throw PanelRegistryError.invalidId(descriptor.id)
        }
        if let existing = descriptors[descriptor.id] {
            if existing == descriptor { return }
            throw PanelRegistryError.duplicateId(descriptor.id)
        }
        descriptors[descriptor.id] = descriptor
        order.append(descriptor.id)
        if states[descriptor.id] == nil {
            states[descriptor.id] = PanelInstanceState.initial(for: descriptor)
        }
    }

    public func unregister(id: String) {
        descriptors.removeValue(forKey: id)
        states.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    /// Wipes everything. Tests use this to start fresh; production code does not.
    public func reset() {
        descriptors.removeAll()
        states.removeAll()
        order.removeAll()
    }

    // MARK: - Read

    public func all() -> [PanelDescriptor] {
        order.compactMap { descriptors[$0] }
    }

    public func descriptor(id: String) -> PanelDescriptor? {
        descriptors[id]
    }

    public func state(id: String) -> PanelInstanceState? {
        states[id]
    }

    public func allStates() -> [PanelInstanceState] {
        order.compactMap { states[$0] }
    }

    public func contains(id: String) -> Bool {
        descriptors[id] != nil
    }

    // MARK: - State mutation

    /// Replaces the state row for `id`. Throws `.unknownId` if the panel was
    /// never registered (we don't want stale state for non-existent panels).
    public func updateState(id: String, _ newState: PanelInstanceState) throws {
        guard descriptors[id] != nil else { throw PanelRegistryError.unknownId(id) }
        var s = newState
        s.id = id
        states[id] = s
    }

    /// Convenience: show a panel at a given position. If `position == nil`,
    /// restores the last docked position, falling back to `defaultPosition`.
    @discardableResult
    public func show(id: String, at position: PanelPosition? = nil) throws -> PanelInstanceState {
        guard let descriptor = descriptors[id] else {
            throw PanelRegistryError.unknownId(id)
        }
        var state = states[id] ?? PanelInstanceState.initial(for: descriptor)

        let target: PanelPosition
        if let position {
            if position == .floating, !descriptor.supportsFloating {
                throw PanelRegistryError.cannotFloat(id)
            }
            target = position
        } else if let last = state.lastDockedPosition, last.isDocked {
            target = last
        } else {
            target = descriptor.defaultPosition
        }

        if target.isDocked {
            state.lastDockedPosition = target
        }
        state.position = target
        state.visible = true
        state.collapsed = false
        states[id] = state
        return state
    }

    @discardableResult
    public func hide(id: String) throws -> PanelInstanceState {
        guard descriptors[id] != nil else { throw PanelRegistryError.unknownId(id) }
        var s = states[id] ?? PanelInstanceState.initial(for: descriptors[id]!)
        if s.position.isDocked { s.lastDockedPosition = s.position }
        s.position = .hidden
        s.visible = false
        states[id] = s
        return s
    }

    @discardableResult
    public func float(id: String, frame: CGRect? = nil) throws -> PanelInstanceState {
        guard let d = descriptors[id] else { throw PanelRegistryError.unknownId(id) }
        guard d.supportsFloating else { throw PanelRegistryError.cannotFloat(id) }
        var s = states[id] ?? PanelInstanceState.initial(for: d)
        if s.position.isDocked { s.lastDockedPosition = s.position }
        s.position = .floating
        s.visible = true
        s.floatingFrame = frame ?? s.floatingFrame ?? CGRect(
            origin: .zero,
            size: d.preferredSize
        )
        states[id] = s
        return s
    }
}
