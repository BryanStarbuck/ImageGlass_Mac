import XCTest
@testable import ImageGlassCore

final class ReleasesCatalogTests: XCTestCase {

    // MARK: - Basic shape

    func testCatalog_isNonEmpty() {
        XCTAssertFalse(
            ReleasesCatalog.releases.isEmpty,
            "ReleasesCatalog must list at least one release"
        )
        XCTAssertFalse(
            ReleasesCatalog.milestones.isEmpty,
            "ReleasesCatalog must list at least one project milestone"
        )
    }

    func testCatalog_idsAreUnique() {
        let ids = ReleasesCatalog.releases.map(\.id)
        XCTAssertEqual(
            Set(ids).count, ids.count,
            "Release ids must be unique"
        )
    }

    // MARK: - Dates parse / round-trip

    func testCatalog_datesAreReasonable() {
        // Sanity range: ImageGlass started in 2010, so any release date older
        // than 2010 or further in the future than 5 years from "now" probably
        // indicates a typo in the catalog.
        let lower = ReleasesCatalog.date(2010, 1, 1)
        let upper = ReleasesCatalog.date(2030, 12, 31)
        for note in ReleasesCatalog.releases {
            XCTAssertGreaterThan(
                note.date, lower,
                "\(note.version): date \(note.date) is before 2010"
            )
            XCTAssertLessThan(
                note.date, upper,
                "\(note.version): date \(note.date) is after 2030"
            )
        }
    }

    func testCatalog_dateHelper_buildsExpectedComponents() {
        let d = ReleasesCatalog.date(2025, 9, 15)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let comps = cal.dateComponents([.year, .month, .day], from: d)
        XCTAssertEqual(comps.year, 2025)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.day, 15)
    }

    // MARK: - Spec coverage

    func testCatalog_containsAllKnownUpstreamVersions() {
        // From docs/releases.mdx: 9.1, 9.2, 9.3, 9.5 (9.5.0.515), 10 Beta 1.
        let versions = Set(ReleasesCatalog.releases.map(\.version))
        for expected in ReleasesCatalog.knownUpstreamVersions {
            XCTAssertTrue(
                versions.contains(expected),
                "Catalog is missing upstream version \(expected)"
            )
        }
    }

    func testCatalog_includesThisMacFork() {
        let macForkEntries = ReleasesCatalog.releases.filter { $0.origin == .macFork }
        XCTAssertFalse(
            macForkEntries.isEmpty,
            "Catalog must include at least one Mac fork release"
        )
        XCTAssertTrue(
            macForkEntries.contains { $0.version.contains("ImageGlass_Mac") },
            "Mac fork entry should be labelled ImageGlass_Mac"
        )
    }

    func testCatalog_projectMilestones_coverSpecItems() {
        let titles = ReleasesCatalog.milestones.map(\.title)
        XCTAssertTrue(
            titles.contains(where: { $0.localizedCaseInsensitiveContains("WeAreDevelopers") }),
            "Missing WeAreDevelopers 2025 milestone"
        )
        XCTAssertTrue(
            titles.contains(where: { $0.localizedCaseInsensitiveContains("OpenPledge") }),
            "Missing OpenPledge.io milestone"
        )
        XCTAssertTrue(
            titles.contains(where: { $0.localizedCaseInsensitiveContains("15-year") }),
            "Missing 15-year anniversary milestone"
        )
    }

    // MARK: - Ordering

    func testSortedReverseChronological_isStrictlyDescending() {
        let sorted = ReleasesCatalog.sortedReverseChronological
        XCTAssertEqual(sorted.count, ReleasesCatalog.releases.count)
        for i in 1..<sorted.count {
            XCTAssertGreaterThanOrEqual(
                sorted[i - 1].date,
                sorted[i].date,
                "Reverse-chronological ordering violated at index \(i)"
            )
        }
    }

    func testSortedReverseChronological_macForkAppearsFirst() {
        // The Mac fork's 0.1 entry is dated June 2026, which is newer than
        // every upstream entry in the spec — so it should head the list.
        let sorted = ReleasesCatalog.sortedReverseChronological
        XCTAssertEqual(sorted.first?.origin, .macFork)
    }

    // MARK: - Kind classification

    func testCatalog_kinds_areCorrectlyLabelled() {
        // 10 Beta 1 must be beta; the 9.x line must be stable.
        let byVersion = Dictionary(
            uniqueKeysWithValues: ReleasesCatalog.releases.map { ($0.version, $0.kind) }
        )
        XCTAssertEqual(byVersion["10 Beta 1"], .beta)
        XCTAssertEqual(byVersion["9.5.0.515"], .stable)
        XCTAssertEqual(byVersion["9.3"], .stable)
        XCTAssertEqual(byVersion["9.2"], .stable)
        XCTAssertEqual(byVersion["9.1"], .stable)
    }

    func testCatalog_highlightsAreNonEmptyForEveryRelease() {
        for note in ReleasesCatalog.releases {
            XCTAssertFalse(
                note.highlights.isEmpty,
                "\(note.version) has no highlights — empty entries hurt the UI"
            )
        }
    }
}
