import XCTest
import Foundation
@testable import ImageGlassCore

final class PanelLayoutTests: XCTestCase {

    // MARK: - Serialization

    func testRoundTripLayoutJSON() throws {
        let layout = BuiltInPreset.browser.layout()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(layout)
        let dec = JSONDecoder()
        let decoded = try dec.decode(PanelLayout.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, PanelLayout.currentSchemaVersion)
        XCTAssertEqual(decoded.activePreset, "Browser")
        XCTAssertEqual(decoded.groups.count, layout.groups.count)
    }

    func testWireValuesMatchSpec() {
        XCTAssertEqual(DockPosition.left.wireValue, "left")
        XCTAssertEqual(DockPosition.centerOverlay.wireValue, "center_overlay")
        XCTAssertEqual(DockPosition.fromWire("center_overlay"), .centerOverlay)
        XCTAssertNil(DockPosition.fromWire("middle"))
    }

    // MARK: - Validation

    func testValidationRejectsDuplicatePanel() {
        let layout = PanelLayout(
            groups: [
                TabGroup(position: .left, panelIDs: ["a"], activeIndex: 0),
                TabGroup(position: .right, panelIDs: ["a"], activeIndex: 0),
            ],
            floating: [],
            hidden: [:],
            activePreset: ""
        )
        XCTAssertNotNil(PanelLayoutValidator.validate(layout))
    }

    func testValidationAcceptsBuiltInPresets() {
        for preset in BuiltInPreset.allCases {
            XCTAssertNil(PanelLayoutValidator.validate(preset.layout()),
                         "built-in preset '\(preset.rawValue)' should validate")
        }
    }

    // MARK: - Mutations

    func testShowHideRoundTripPreservesPosition() throws {
        var layout = BuiltInPreset.browser.layout()
        XCTAssertTrue(layout.isVisible("file_panel"))
        layout = try PanelLayoutMutations.hidePanel(layout, id: "file_panel")
        XCTAssertFalse(layout.isVisible("file_panel"))
        XCTAssertEqual(layout.hidden["file_panel"]?.lastPosition, .left)
        layout = PanelLayoutMutations.showPanel(layout, id: "file_panel")
        XCTAssertEqual(layout.position(of: "file_panel"), .left)
    }

    func testCannotHideLastVisiblePanel() throws {
        var layout = PanelLayout(
            groups: [TabGroup(position: .left, panelIDs: ["only"], activeIndex: 0)],
            floating: [],
            hidden: [:],
            activePreset: ""
        )
        XCTAssertThrowsError(try {
            layout = try PanelLayoutMutations.hidePanel(layout, id: "only")
        }())
        XCTAssertTrue(layout.isVisible("only"))
    }

    func testMoveBetweenPositions() throws {
        var layout = BuiltInPreset.browser.layout()
        layout = try PanelLayoutMutations.movePanel(layout, id: "file_panel", to: .right)
        XCTAssertEqual(layout.position(of: "file_panel"), .right)
        layout = try PanelLayoutMutations.movePanel(layout, id: "file_panel", to: .floating)
        XCTAssertEqual(layout.position(of: "file_panel"), .floating)
    }

    func testTabAndUntab() throws {
        var layout = BuiltInPreset.browser.layout()
        // file_panel and scope_editor already share a tab group.
        layout = try PanelLayoutMutations.untabPanel(layout, id: "scope_editor")
        let groupsAtLeft = layout.groups.filter { $0.position == .left }
        XCTAssertEqual(groupsAtLeft.count, 2,
                       "untab should produce two left-dock groups")
        layout = try PanelLayoutMutations.tabPanels(layout, targetID: "file_panel", sourceID: "scope_editor")
        let g = layout.locate(panelID: "scope_editor")?.group
        XCTAssertNotNil(g)
        XCTAssertTrue(g?.panelIDs.contains("file_panel") == true)
    }

    func testSetPanelSizeRespectsMin() throws {
        var layout = BuiltInPreset.browser.layout()
        layout = try PanelLayoutMutations.setPanelSize(layout, id: "file_panel", size: 10, minSize: 64)
        let g = layout.locate(panelID: "file_panel")!.group
        XCTAssertEqual(g.size, 64)
    }

    // MARK: - Catalog

    func testEveryPanelInPresetExistsInCatalog() {
        for preset in BuiltInPreset.allCases {
            let l = preset.layout()
            for g in l.groups {
                for pid in g.panelIDs {
                    XCTAssertNotNil(BuiltInPanelCatalog.descriptor(for: pid),
                                    "preset '\(preset.rawValue)' references unknown panel '\(pid)'")
                }
            }
            for f in l.floating {
                XCTAssertNotNil(BuiltInPanelCatalog.descriptor(for: f.id),
                                "preset '\(preset.rawValue)' references unknown floating panel '\(f.id)'")
            }
        }
    }

    // MARK: - Store

    // MARK: - showPanelAsPrimary (docs/panels.mdx §6.5)

    /// `file_panel` was hidden but the left dock already holds another
    /// panel (the user's drift case). `showPanelAsPrimary` must
    /// prepend `file_panel` and make it the active tab, never append
    /// it behind the existing occupant.
    func testShowPanelAsPrimaryPrependsToExistingGroup() {
        var layout = PanelLayout(
            groups: [
                TabGroup(position: .left,
                         panelIDs: ["scope_editor"],
                         activeIndex: 0,
                         size: 280),
            ],
            floating: [],
            hidden: [
                "file_panel": HiddenPanelState(
                    lastPosition: .left,
                    lastSize: .init(width: 280, height: 600)
                )
            ],
            activePreset: ""
        )
        layout = PanelLayoutMutations.showPanelAsPrimary(layout, id: "file_panel")
        let left = layout.groups.first { $0.position == .left }!
        XCTAssertEqual(left.panelIDs, ["file_panel", "scope_editor"],
                       "file_panel should be inserted at index 0")
        XCTAssertEqual(left.activeIndex, 0,
                       "file_panel should be the active tab in its group")
        XCTAssertNil(layout.hidden["file_panel"],
                     "hidden entry should be cleared on restore")
    }

    /// When `file_panel` is already visible but it's the second tab
    /// (not the primary), `showPanelAsPrimary` must promote it to the
    /// front of its group rather than be a no-op.
    func testShowPanelAsPrimaryPromotesExistingTab() {
        var layout = PanelLayout(
            groups: [
                TabGroup(position: .left,
                         panelIDs: ["scope_editor", "file_panel"],
                         activeIndex: 0,
                         size: 280),
            ],
            floating: [],
            hidden: [:],
            activePreset: ""
        )
        layout = PanelLayoutMutations.showPanelAsPrimary(layout, id: "file_panel")
        let left = layout.groups.first { $0.position == .left }!
        XCTAssertEqual(left.panelIDs, ["file_panel", "scope_editor"])
        XCTAssertEqual(left.activeIndex, 0)
    }

    /// When no left group exists at all, the panel must create one at
    /// its default position.
    func testShowPanelAsPrimaryCreatesGroupWhenAbsent() {
        var layout = PanelLayout(
            groups: [TabGroup(position: .top, panelIDs: ["toolbar"], activeIndex: 0)],
            floating: [],
            hidden: [:],
            activePreset: ""
        )
        layout = PanelLayoutMutations.showPanelAsPrimary(layout, id: "file_panel",
                                                          defaultPosition: .left,
                                                          defaultSize: .init(width: 280, height: 600))
        let left = layout.groups.first { $0.position == .left }!
        XCTAssertEqual(left.panelIDs, ["file_panel"])
        XCTAssertEqual(left.activeIndex, 0)
        XCTAssertEqual(left.size, 280)
    }

    // MARK: - PanelStateYAML mirror

    func testPanelStateYAMLEncodesVisibleAndHidden() {
        let layout = PanelLayout(
            groups: [
                TabGroup(position: .left,
                         panelIDs: ["file_panel"],
                         activeIndex: 0,
                         size: 280),
            ],
            floating: [],
            hidden: [
                "scope_editor": HiddenPanelState(
                    lastPosition: .left,
                    lastSize: .init(width: 280, height: 400)
                )
            ],
            activePreset: "Browser"
        )
        let yaml = PanelStateYAML.encode(layout)
        XCTAssertTrue(yaml.contains("schema_version: 1"))
        XCTAssertTrue(yaml.contains("active_preset: Browser"))
        XCTAssertTrue(yaml.contains("- id: file_panel"))
        XCTAssertTrue(yaml.contains("visible: true"))
        XCTAssertTrue(yaml.contains("position: left"))
        XCTAssertTrue(yaml.contains("size: 280"))
        XCTAssertTrue(yaml.contains("- id: scope_editor"))
        XCTAssertTrue(yaml.contains("visible: false"))
        XCTAssertTrue(yaml.contains("last_position: left"))
        XCTAssertTrue(yaml.contains("last_size: [280, 400]"))
    }

    func testPanelStateYAMLStoreWritesAtomic() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ig_panels_yaml_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PanelStateYAMLStore()
        store.fileOverride = dir.appendingPathComponent("panels.yaml")
        try store.save(BuiltInPreset.browser.layout())
        let written = try String(contentsOf: store.fileOverride!, encoding: .utf8)
        XCTAssertTrue(written.contains("- id: file_panel"))
        XCTAssertTrue(written.contains("visible: true"))
    }

    // MARK: - Store

    func testLayoutStoreRoundTrip() throws {
        // Redirect HOME to a temp dir so we don't touch the user's real
        // Application Support during the test.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ig_panel_store_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("HOME", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LayoutStore()
        let saved = BuiltInPreset.photographer.layout()
        try store.save(saved)
        let loaded = store.load()
        XCTAssertEqual(loaded.activePreset, "Photographer")
        XCTAssertEqual(loaded.groups.count, saved.groups.count)
    }

    func testCannotOverwriteBuiltInPreset() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ig_panel_store_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("HOME", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LayoutStore()
        XCTAssertThrowsError(try store.saveUserPreset(name: "Browser", layout: PresetCatalog.defaultLayout))
    }
}
