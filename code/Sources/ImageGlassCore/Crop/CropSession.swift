import Foundation
import CoreGraphics

/// Shared, in-process bridge between the SwiftUI `CropController` and
/// the MCP tools `get_crop_selection` / `set_crop_selection`
/// (`docs/crop.mdx §7.2 / §7.3`).
///
/// The app's controller writes the GUI's current selection here on
/// every change; the MCP tools read from / write to this same instance
/// so an LLM can both inspect the user's selection and pre-fill a
/// proposal for the user to confirm.
///
/// Out-of-process MCP clients (the `imageglass-mcp` stdio binary
/// launched independently of the GUI) won't share this object, so
/// those tools degrade to "no active GUI" responses — the MCP
/// `crop_image` tool is still fully usable headless because it
/// operates on the file system directly.
public final class CropSession: @unchecked Sendable {

    public static let shared = CropSession()

    private let lock = NSLock()

    public struct State: Sendable, Equatable {
        public var rect: CGRect?
        public var aspectRatio: SelectionAspectRatio
        public var imagePath: String?
        public init(
            rect: CGRect? = nil,
            aspectRatio: SelectionAspectRatio = .freeRatio,
            imagePath: String? = nil
        ) {
            self.rect = rect
            self.aspectRatio = aspectRatio
            self.imagePath = imagePath
        }
    }

    private var _state: State = State()

    /// Pending selection that an external caller (MCP) has set and that
    /// the GUI has not yet consumed. The GUI polls `consumePending()`
    /// from its run loop and applies it.
    public struct Pending: Sendable, Equatable {
        public var rect: CGRect
        public var aspectRatio: SelectionAspectRatio?
    }
    private var _pending: Pending?

    public init() {}

    public func snapshot() -> State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public func update(_ state: State) {
        lock.lock(); defer { lock.unlock() }
        _state = state
    }

    public func setRect(_ rect: CGRect?) {
        lock.lock(); defer { lock.unlock() }
        _state.rect = rect
    }

    public func setAspectRatio(_ aspect: SelectionAspectRatio) {
        lock.lock(); defer { lock.unlock() }
        _state.aspectRatio = aspect
    }

    public func setImagePath(_ path: String?) {
        lock.lock(); defer { lock.unlock() }
        _state.imagePath = path
    }

    /// External caller (MCP) proposes a new selection.
    public func propose(_ pending: Pending) {
        lock.lock(); defer { lock.unlock() }
        _pending = pending
    }

    /// GUI consumes the pending selection (returns nil if nothing pending).
    public func consumePending() -> Pending? {
        lock.lock(); defer { lock.unlock() }
        let p = _pending
        _pending = nil
        return p
    }
}
