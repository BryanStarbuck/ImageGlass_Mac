import XCTest
@testable import ImageGlassCore

final class LayoutDirectorTests: XCTestCase {

    // MARK: - Preset application

    func testBuiltinBrowserAppliesFilePanelLeft() {
        let registered: Set<String> = ["file_panel", "toolbar", "status_bar",
                                       "thumbnail_strip", "histogram"]
        let states = LayoutDirector.instanceStates(
            for: .browser,
            registered: registered
        )
        let byId = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        XCTAssertEqual(byId["file_panel"]?.position, .left)
        XCTAssertTrue(byId["file_panel"]?.visible ?? false)
        XCTAssertEqual(byId["toolbar"]?.position, .top)
        XCTAssertEqual(byId["status_bar"]?.position, .bottom)
        // Not authored into "browser" — must come back hidden.
        XCTAssertEqual(byId["histogram"]?.position, .hidden)
        XCTAssertFalse(byId["histogram"]?.visible ?? true)
    }

    func testPowerUserPresetIncludesFloatingColorPicker() {
        let registered: Set<String> = ["scope_panel", "file_panel", "mcp_panel",
                                       "local_storage_browser", "toolbar",
                                       "status_bar", "color_picker"]
        let states = LayoutDirector.instanceStates(
            for: .powerUser,
            registered: registered
        )
        let byId = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        XCTAssertEqual(byId["color_picker"]?.position, .floating)
        XCTAssertEqual(byId["color_picker"]?.floatingFrame,
                       CGRect(x: 1500, y: 700, width: 280, height: 240))
        XCTAssertEqual(byId["scope_panel"]?.position, .left)
        XCTAssertEqual(byId["mcp_panel"]?.position, .right)
    }

    func testUnknownPanelsSkippedSilently() {
        // Preset references panels we did not register — must not crash.
        let registered: Set<String> = ["toolbar"]
        let states = LayoutDirector.instanceStates(
            for: .powerUser,
            registered: registered
        )
        let byId = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        XCTAssertEqual(byId["toolbar"]?.position, .top)
        XCTAssertEqual(byId.count, 1)
    }

    func testDiffReturnsOnlyChangedRows() {
        let current = [
            PanelInstanceState(id: "a", visible: true, position: .left),
            PanelInstanceState(id: "b", visible: false, position: .hidden),
        ]
        let target = [
            PanelInstanceState(id: "a", visible: true, position: .left),     // same
            PanelInstanceState(id: "b", visible: true, position: .right),    // changed
        ]
        let changes = LayoutDirector.diff(current: current, target: target)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.id, "b")
        XCTAssertEqual(changes.first?.position, .right)
    }

    // MARK: - Snap math

    func testPerpendicularDistanceInsideRectIsZero() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let d = LayoutDirector.perpendicularDistance(from: CGPoint(x: 150, y: 150), to: rect)
        XCTAssertEqual(d, 0, accuracy: 0.0001)
    }

    func testPerpendicularDistanceOutsideRect() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 30pt to the right of x=100
        let d = LayoutDirector.perpendicularDistance(from: CGPoint(x: 130, y: 50), to: rect)
        XCTAssertEqual(d, 30, accuracy: 0.0001)
    }

    func testPerpendicularDistanceCornerCase() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 30pt right, 40pt up → distance should be 50 (3-4-5 triangle)
        let d = LayoutDirector.perpendicularDistance(from: CGPoint(x: 130, y: 140), to: rect)
        XCTAssertEqual(d, 50, accuracy: 0.0001)
    }

    func testDockEdgeRectsCornersAreAtFrameEdges() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rects = LayoutDirector.dockEdgeRects(for: frame, edgeThickness: 24)
        XCTAssertEqual(rects[.left]?.minX, 0)
        XCTAssertEqual(rects[.left]?.width, 24)
        XCTAssertEqual(rects[.right]?.maxX, 1000)
        XCTAssertEqual(rects[.right]?.width, 24)
        XCTAssertEqual(rects[.top]?.maxY, 800)
        XCTAssertEqual(rects[.top]?.height, 24)
        XCTAssertEqual(rects[.bottom]?.minY, 0)
        XCTAssertEqual(rects[.bottom]?.height, 24)
    }

    func testNearestSnapTargetSelectsClosestInsideTriggerDistance() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let edges = LayoutDirector.dockEdgeRects(for: frame)
        let targets = edges.map { LayoutDirector.SnapTarget(
            windowId: "main", position: $0.key, edgeRect: $0.value
        ) }
        // Cursor at the right edge — should snap right.
        let result = LayoutDirector.nearestSnapTarget(
            for: CGPoint(x: 990, y: 400),
            targets: targets
        )
        XCTAssertEqual(result?.target.position, .right)
        XCTAssertLessThanOrEqual(result?.distance ?? 99, LayoutDirector.defaultSnapTriggerDistance)
    }

    func testNearestSnapTargetReturnsNilWhenFarFromAllEdges() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let edges = LayoutDirector.dockEdgeRects(for: frame)
        let targets = edges.map { LayoutDirector.SnapTarget(
            windowId: "main", position: $0.key, edgeRect: $0.value
        ) }
        let result = LayoutDirector.nearestSnapTarget(
            for: CGPoint(x: 500, y: 400),  // middle, far from any edge
            targets: targets,
            triggerDistance: 24
        )
        XCTAssertNil(result)
    }
}
