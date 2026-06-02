import XCTest
@testable import ImageGlassCore

final class FileListSorterTests: XCTestCase {

    private func entry(_ path: String, size: Int64? = nil, mtime: Date? = nil,
                       rating: Int? = nil, dim: CGSize? = nil,
                       dateTaken: Date? = nil) -> FileEntry {
        var e = FileEntry(path: path)
        e.size = size
        e.mtime = mtime
        e.rating = rating
        e.dimensions = dim
        e.dateTaken = dateTaken
        return e
    }

    func testNameAscendingUsesNaturalSort() {
        let entries = [
            entry("/a/IMG_10.jpg"),
            entry("/a/IMG_2.jpg"),
            entry("/a/IMG_1.jpg"),
        ]
        let sorted = FileListSorter.sort(entries, by: .init(field: .name, direction: .ascending))
        XCTAssertEqual(sorted.map(\.name), ["IMG_1.jpg", "IMG_2.jpg", "IMG_10.jpg"])
    }

    func testNameDescendingReverses() {
        let entries = [
            entry("/a/IMG_10.jpg"),
            entry("/a/IMG_2.jpg"),
            entry("/a/IMG_1.jpg"),
        ]
        let sorted = FileListSorter.sort(entries, by: .init(field: .name, direction: .descending))
        XCTAssertEqual(sorted.map(\.name), ["IMG_10.jpg", "IMG_2.jpg", "IMG_1.jpg"])
    }

    func testSizeSortNilsLast() {
        let entries = [
            entry("/a/c.jpg", size: nil),
            entry("/a/a.jpg", size: 100),
            entry("/a/b.jpg", size: 10),
        ]
        let sorted = FileListSorter.sort(entries, by: .init(field: .size, direction: .ascending))
        XCTAssertEqual(sorted.map(\.name), ["b.jpg", "a.jpg", "c.jpg"])
    }

    func testTypeSortGroupsByExtensionThenName() {
        let entries = [
            entry("/a/zebra.png"),
            entry("/a/apple.jpg"),
            entry("/a/banana.png"),
            entry("/a/zonk.jpg"),
        ]
        let sorted = FileListSorter.sort(entries, by: .init(field: .type, direction: .ascending))
        XCTAssertEqual(sorted.map(\.name), ["apple.jpg", "zonk.jpg", "banana.png", "zebra.png"])
    }

    func testFilterSubstringCaseAndDiacriticInsensitive() {
        let entries = [
            entry("/a/sunset.jpg"),
            entry("/a/Café.jpg"),
            entry("/a/skyline.jpg"),
            entry("/a/SUNRISE.jpg"),
        ]
        // case-insensitive
        let lc = FileListSorter.filter(entries, text: "sun")
        XCTAssertEqual(Set(lc.map(\.name)), Set(["sunset.jpg", "SUNRISE.jpg"]))
        // diacritic-insensitive
        let dia = FileListSorter.filter(entries, text: "cafe")
        XCTAssertEqual(dia.map(\.name), ["Café.jpg"])
        // empty filter passes everything through
        let all = FileListSorter.filter(entries, text: "   ")
        XCTAssertEqual(all.count, entries.count)
    }

    func testRandomSortIsDeterministicBySeed() {
        let entries = (0..<20).map { entry("/a/file\($0).jpg") }
        let a = FileListSorter.sort(entries, by: .init(field: .random, direction: .ascending, randomSeed: 42))
        let b = FileListSorter.sort(entries, by: .init(field: .random, direction: .ascending, randomSeed: 42))
        let c = FileListSorter.sort(entries, by: .init(field: .random, direction: .ascending, randomSeed: 7))
        XCTAssertEqual(a.map(\.path), b.map(\.path), "same seed → same order")
        XCTAssertNotEqual(a.map(\.path), c.map(\.path), "different seed → different order")
    }

    func testDimensionsSortByPixelCount() {
        let entries = [
            entry("/a/small.jpg", dim: CGSize(width: 100, height: 100)),
            entry("/a/big.jpg",   dim: CGSize(width: 4000, height: 3000)),
            entry("/a/med.jpg",   dim: CGSize(width: 1000, height: 800)),
        ]
        let sorted = FileListSorter.sort(entries, by: .init(field: .dimensions, direction: .ascending))
        XCTAssertEqual(sorted.map(\.name), ["small.jpg", "med.jpg", "big.jpg"])
    }
}
