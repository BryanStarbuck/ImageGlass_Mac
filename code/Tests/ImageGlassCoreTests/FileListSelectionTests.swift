import XCTest
@testable import ImageGlassCore

final class FileListSelectionTests: XCTestCase {

    private let visible = ["/a/1.jpg", "/a/2.jpg", "/a/3.jpg", "/a/4.jpg", "/a/5.jpg"]

    func testClickReplacesSelectionAndSetsFocus() {
        let s0 = FileListSelectionState(selected: ["/a/4.jpg"], focused: "/a/4.jpg")
        let s1 = FileListSelection.apply(.click("/a/2.jpg"), to: s0, visible: visible)
        XCTAssertEqual(s1.selected, ["/a/2.jpg"])
        XCTAssertEqual(s1.focused, "/a/2.jpg")
        XCTAssertTrue(s1.focusIsConsistent())
        XCTAssertTrue(s1.isSubset(of: visible))
    }

    func testShiftClickSelectsRangeFromFocus() {
        let s0 = FileListSelectionState(selected: ["/a/1.jpg"], focused: "/a/1.jpg")
        let s1 = FileListSelection.apply(.shiftClick("/a/4.jpg"), to: s0, visible: visible)
        XCTAssertEqual(s1.selected, Set(["/a/1.jpg", "/a/2.jpg", "/a/3.jpg", "/a/4.jpg"]))
        XCTAssertEqual(s1.focused, "/a/4.jpg")
    }

    func testShiftClickFromHigherIndexBackwards() {
        let s0 = FileListSelectionState(selected: ["/a/5.jpg"], focused: "/a/5.jpg")
        let s1 = FileListSelection.apply(.shiftClick("/a/2.jpg"), to: s0, visible: visible)
        XCTAssertEqual(s1.selected, Set(["/a/2.jpg", "/a/3.jpg", "/a/4.jpg", "/a/5.jpg"]))
        XCTAssertEqual(s1.focused, "/a/2.jpg")
    }

    func testCmdClickTogglesSingleItem() {
        let s0 = FileListSelectionState(selected: ["/a/2.jpg"], focused: "/a/2.jpg")
        let s1 = FileListSelection.apply(.cmdClick("/a/4.jpg"), to: s0, visible: visible)
        XCTAssertEqual(s1.selected, Set(["/a/2.jpg", "/a/4.jpg"]))
        let s2 = FileListSelection.apply(.cmdClick("/a/2.jpg"), to: s1, visible: visible)
        XCTAssertEqual(s2.selected, Set(["/a/4.jpg"]))
    }

    func testSelectAllUsesVisibleList() {
        let s0 = FileListSelectionState.empty
        let s1 = FileListSelection.apply(.selectAll, to: s0, visible: visible)
        XCTAssertEqual(s1.selected, Set(visible))
        XCTAssertEqual(s1.focused, "/a/1.jpg")
    }

    func testClearLeavesFocus() {
        let s0 = FileListSelectionState(selected: ["/a/1.jpg", "/a/2.jpg"], focused: "/a/2.jpg")
        let s1 = FileListSelection.apply(.clear, to: s0, visible: visible)
        XCTAssertTrue(s1.selected.isEmpty)
        XCTAssertEqual(s1.focused, "/a/2.jpg")
        XCTAssertTrue(s1.focusIsConsistent(), "empty selection is always consistent with focus")
    }

    func testMoveFocusForwardWrapsAtBounds() {
        let s0 = FileListSelectionState(selected: ["/a/4.jpg"], focused: "/a/4.jpg")
        let s1 = FileListSelection.apply(.moveFocus(offset: 1, extending: false), to: s0, visible: visible)
        XCTAssertEqual(s1.focused, "/a/5.jpg")
        let s2 = FileListSelection.apply(.moveFocus(offset: 5, extending: false), to: s1, visible: visible)
        XCTAssertEqual(s2.focused, "/a/5.jpg", "clamps to last item, not wrap-around")
    }

    func testMoveFocusBackwardClampsAtZero() {
        let s0 = FileListSelectionState(selected: ["/a/2.jpg"], focused: "/a/2.jpg")
        let s1 = FileListSelection.apply(.moveFocus(offset: -10, extending: false), to: s0, visible: visible)
        XCTAssertEqual(s1.focused, "/a/1.jpg")
    }

    func testMoveFocusExtendingExtendsRange() {
        let s0 = FileListSelectionState(selected: ["/a/2.jpg"], focused: "/a/2.jpg")
        let s1 = FileListSelection.apply(.moveFocus(offset: 2, extending: true), to: s0, visible: visible)
        XCTAssertEqual(s1.selected, Set(["/a/2.jpg", "/a/3.jpg", "/a/4.jpg"]))
        XCTAssertEqual(s1.focused, "/a/4.jpg")
    }

    func testSetManyFiltersToVisibleSet() {
        // Path "/a/9.jpg" isn't in visible — should be ignored.
        let s0 = FileListSelectionState.empty
        let s1 = FileListSelection.apply(.setMany(["/a/1.jpg", "/a/9.jpg", "/a/3.jpg"]), to: s0, visible: visible)
        XCTAssertEqual(s1.selected, Set(["/a/1.jpg", "/a/3.jpg"]))
        XCTAssertTrue(s1.isSubset(of: visible))
    }

    func testEmptyVisibleNeverCrashes() {
        let s0 = FileListSelectionState.empty
        let s1 = FileListSelection.apply(.click("/x.jpg"), to: s0, visible: [])
        XCTAssertEqual(s1.selected, ["/x.jpg"])
        let s2 = FileListSelection.apply(.moveFocus(offset: 1, extending: false), to: s1, visible: [])
        // visible is empty — focus unchanged.
        XCTAssertEqual(s2.focused, "/x.jpg")
    }
}
