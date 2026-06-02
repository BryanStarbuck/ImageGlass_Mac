import XCTest
@testable import ImageGlassCore

final class FileListTreeBuilderTests: XCTestCase {

    func testGroupsLeavesUnderSourceRoots() {
        let entries = [
            FileEntry(path: "/Volumes/Photos/2026/Maui/DSC_0001.NEF", sourceIndex: 0,
                      sourceDirectory: "/Volumes/Photos/2026/Maui"),
            FileEntry(path: "/Volumes/Photos/2026/Maui/DSC_0002.NEF", sourceIndex: 0,
                      sourceDirectory: "/Volumes/Photos/2026/Maui"),
            FileEntry(path: "/Volumes/Photos/2026/Big_Sur/Sunset/sunset_001.jpg", sourceIndex: 1,
                      sourceDirectory: "/Volumes/Photos/2026/Big_Sur"),
        ]
        let dirs = [
            "/Volumes/Photos/2026/Maui",
            "/Volumes/Photos/2026/Big_Sur",
        ]
        let tree = FileListTreeBuilder.build(entries: entries, sourceDirectories: dirs)
        XCTAssertEqual(tree.count, 2)
        XCTAssertEqual(tree[0].sourceIndex, 0)
        XCTAssertEqual(tree[0].name, "/Volumes/Photos/2026/Maui")
        XCTAssertEqual(tree[0].children?.count, 2)
        // Big_Sur should have a Sunset subdirectory wrapping the leaf.
        let bigSur = tree[1]
        XCTAssertEqual(bigSur.children?.count, 1)
        XCTAssertEqual(bigSur.children?[0].name, "Sunset")
        XCTAssertEqual(bigSur.children?[0].isDirectory, true)
        XCTAssertEqual(bigSur.children?[0].children?[0].name, "sunset_001.jpg")
        XCTAssertEqual(bigSur.children?[0].children?[0].isDirectory, false)
        XCTAssertEqual(bigSur.children?[0].children?[0].filePath,
                       "/Volumes/Photos/2026/Big_Sur/Sunset/sunset_001.jpg")
    }

    func testEmptySourceDirectoryIsOmitted() {
        let entries = [
            FileEntry(path: "/a/x.jpg", sourceIndex: 0, sourceDirectory: "/a"),
        ]
        let dirs = ["/a", "/b"]  // /b has no entries.
        let tree = FileListTreeBuilder.build(entries: entries, sourceDirectories: dirs)
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "/a")
    }

    func testOrphanEntryGetsSyntheticOtherRoot() {
        // Entry with sourceIndex = 5 but only one configured source dir.
        let entries = [
            FileEntry(path: "/a/x.jpg", sourceIndex: 5, sourceDirectory: "/a"),
        ]
        let dirs = ["/a"]
        let tree = FileListTreeBuilder.build(entries: entries, sourceDirectories: dirs)
        XCTAssertEqual(tree.count, 1, "no entries match index 0; synthetic Other root holds orphans")
        XCTAssertEqual(tree[0].name, "Other")
        XCTAssertNil(tree[0].sourceIndex)
    }

    func testRelativeComponentsUnderSource() {
        XCTAssertEqual(
            FileListTreeBuilder.relativeComponents(
                for: "/Volumes/Photos/2026/Maui/DSC_0001.NEF",
                under: "/Volumes/Photos/2026/Maui"
            ),
            ["DSC_0001.NEF"]
        )
        XCTAssertEqual(
            FileListTreeBuilder.relativeComponents(
                for: "/Volumes/Photos/2026/Big_Sur/Sunset/sunset_001.jpg",
                under: "/Volumes/Photos/2026/Big_Sur"
            ),
            ["Sunset", "sunset_001.jpg"]
        )
        // Path not under source: degrades to filename-only.
        XCTAssertEqual(
            FileListTreeBuilder.relativeComponents(
                for: "/elsewhere/x.jpg",
                under: "/somewhere"
            ),
            ["x.jpg"]
        )
    }

    func testSiblingsAreSortedDirectoriesFirstThenNatural() {
        let entries = [
            FileEntry(path: "/r/zeta.jpg", sourceIndex: 0, sourceDirectory: "/r"),
            FileEntry(path: "/r/alpha.jpg", sourceIndex: 0, sourceDirectory: "/r"),
            FileEntry(path: "/r/sub/img_2.jpg", sourceIndex: 0, sourceDirectory: "/r"),
            FileEntry(path: "/r/sub/img_10.jpg", sourceIndex: 0, sourceDirectory: "/r"),
            FileEntry(path: "/r/sub/img_1.jpg", sourceIndex: 0, sourceDirectory: "/r"),
        ]
        let tree = FileListTreeBuilder.build(entries: entries, sourceDirectories: ["/r"])
        guard let root = tree.first, let kids = root.children else {
            XCTFail("no root"); return
        }
        // Directory ("sub") should sort before files.
        XCTAssertEqual(kids.first?.name, "sub")
        XCTAssertEqual(kids.first?.isDirectory, true)
        // Inside `sub`, files should be in natural order.
        let inner = kids.first?.children ?? []
        XCTAssertEqual(inner.map(\.name), ["img_1.jpg", "img_2.jpg", "img_10.jpg"])
    }
}
