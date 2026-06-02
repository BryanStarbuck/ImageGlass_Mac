import XCTest
@testable import ImageGlassCore

final class PanelRegistryTests: XCTestCase {

    private func makeDescriptor(id: String, floats: Bool = true) -> PanelDescriptor {
        PanelDescriptor(
            id: id,
            title: id,
            icon: "doc",
            minSize: CGSize(width: 100, height: 100),
            preferredSize: CGSize(width: 200, height: 200),
            maxSize: CGSize(width: 400, height: 400),
            defaultPosition: .left,
            supportsFloating: floats
        )
    }

    // MARK: - Id validation

    func testValidIdsAccepted() {
        for id in ["abc", "scope_panel", "mcp_panel", "file_tree", "a01", "x_2_y_3"] {
            XCTAssertTrue(PanelDescriptor.isValidId(id), "expected '\(id)' to be valid")
        }
    }

    func testInvalidIdsRejected() {
        for id in [
            "ab",                  // too short
            "ABC",                 // uppercase
            "_leading",            // starts with underscore
            "1abc",                // starts with digit
            "with space",          // space
            "has-dash",            // dash
            "trailing.",           // dot
            String(repeating: "a", count: 65)   // too long
        ] {
            XCTAssertFalse(PanelDescriptor.isValidId(id), "expected '\(id)' to be invalid")
        }
    }

    // MARK: - Registration

    func testRegisterAndLookup() async throws {
        let r = PanelRegistry()
        try await r.register(makeDescriptor(id: "alpha"))
        try await r.register(makeDescriptor(id: "beta"))
        let all = await r.all().map(\.id)
        XCTAssertEqual(all, ["alpha", "beta"])
        let lookup = await r.descriptor(id: "alpha")
        XCTAssertEqual(lookup?.id, "alpha")
    }

    func testInvalidIdRejected() async {
        let r = PanelRegistry()
        do {
            try await r.register(makeDescriptor(id: "AB"))
            XCTFail("expected throw")
        } catch let e as PanelRegistryError {
            XCTAssertEqual(e, .invalidId("AB"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testDuplicateIdRejected() async throws {
        let r = PanelRegistry()
        try await r.register(makeDescriptor(id: "twin"))
        do {
            // different descriptor (different size) — should throw
            try await r.register(PanelDescriptor(
                id: "twin",
                title: "twin",
                icon: "x",
                minSize: .zero,
                preferredSize: CGSize(width: 1, height: 1),
                maxSize: CGSize(width: 2, height: 2),
                defaultPosition: .right,
                supportsFloating: true
            ))
            XCTFail("expected throw")
        } catch let e as PanelRegistryError {
            XCTAssertEqual(e, .duplicateId("twin"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testIdempotentReRegistration() async throws {
        let r = PanelRegistry()
        let d = makeDescriptor(id: "alpha")
        try await r.register(d)
        try await r.register(d)  // same descriptor, must not throw
        let all = await r.all().map(\.id)
        XCTAssertEqual(all, ["alpha"])
    }

    // MARK: - State

    func testShowSetsLastDockedAndVisible() async throws {
        let r = PanelRegistry()
        try await r.register(makeDescriptor(id: "alpha"))
        let state = try await r.show(id: "alpha", at: .right)
        XCTAssertEqual(state.position, .right)
        XCTAssertEqual(state.lastDockedPosition, .right)
        XCTAssertTrue(state.visible)
    }

    func testShowFloatRespectsSupportsFloating() async throws {
        let r = PanelRegistry()
        try await r.register(makeDescriptor(id: "pinned", floats: false))
        do {
            _ = try await r.show(id: "pinned", at: .floating)
            XCTFail("expected throw")
        } catch let e as PanelRegistryError {
            XCTAssertEqual(e, .cannotFloat("pinned"))
        }
    }

    func testHidePreservesLastDocked() async throws {
        let r = PanelRegistry()
        try await r.register(makeDescriptor(id: "alpha"))
        _ = try await r.show(id: "alpha", at: .right)
        let hidden = try await r.hide(id: "alpha")
        XCTAssertEqual(hidden.position, .hidden)
        XCTAssertEqual(hidden.lastDockedPosition, .right)
        XCTAssertFalse(hidden.visible)
    }

    func testShowAfterHideRestoresLastDocked() async throws {
        let r = PanelRegistry()
        try await r.register(makeDescriptor(id: "alpha"))
        _ = try await r.show(id: "alpha", at: .bottom)
        _ = try await r.hide(id: "alpha")
        let restored = try await r.show(id: "alpha")  // no explicit position
        XCTAssertEqual(restored.position, .bottom)
    }

    func testUnknownIdThrows() async {
        let r = PanelRegistry()
        do {
            _ = try await r.show(id: "missing")
            XCTFail("expected throw")
        } catch let e as PanelRegistryError {
            XCTAssertEqual(e, .unknownId("missing"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFloatStoresFrame() async throws {
        let r = PanelRegistry()
        try await r.register(makeDescriptor(id: "alpha"))
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let state = try await r.float(id: "alpha", frame: frame)
        XCTAssertEqual(state.position, .floating)
        XCTAssertEqual(state.floatingFrame, frame)
    }
}
