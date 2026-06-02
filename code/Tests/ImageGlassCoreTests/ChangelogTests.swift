import XCTest
@testable import ImageGlassCore

final class ChangelogTests: XCTestCase {

    func testEntries_areReverseChronologicalAndNonEmpty() {
        let entries = Changelog.entries
        XCTAssertFalse(entries.isEmpty)
        for i in 1..<entries.count {
            XCTAssertGreaterThanOrEqual(entries[i - 1].date, entries[i].date)
        }
    }

    func testMacForkEntries_containAtLeastOne() {
        let mac = Changelog.macForkEntries
        XCTAssertFalse(mac.isEmpty)
        XCTAssertTrue(mac.allSatisfy { $0.origin == .macFork })
    }

    func testUpstreamEntries_containAllKnownVersions() {
        let upstream = Changelog.upstreamEntries
        let versions = Set(upstream.map(\.version))
        for v in ReleasesCatalog.knownUpstreamVersions {
            XCTAssertTrue(versions.contains(v), "Missing upstream changelog entry \(v)")
        }
    }

    func testRenderMarkdown_includesAllBullets() {
        guard let entry = Changelog.macForkEntries.first else {
            XCTFail("No Mac fork entries to render")
            return
        }
        let md = Changelog.renderMarkdown(entry)
        XCTAssertTrue(md.hasPrefix("## \(entry.version) — "))
        for bullet in entry.bullets {
            XCTAssertTrue(md.contains("- \(bullet)"), "Bullet '\(bullet)' missing from rendered markdown")
        }
    }

    func testRenderFullMarkdown_includesEveryEntry() {
        let full = Changelog.renderFullMarkdown()
        for entry in Changelog.entries {
            XCTAssertTrue(full.contains(entry.version),
                          "Full changelog missing version \(entry.version)")
        }
    }

    // MARK: - Spec coverage on catalog additions

    func testCatalog_hasEndOfLifeSeriesEntryFor8x() {
        let eol = ReleasesCatalog.endOfLifeSeries
        XCTAssertTrue(eol.contains(where: { $0.series == "8.x" }))
    }

    func testCatalog_hasThreeRoadmapThemes() {
        let themes = ReleasesCatalog.roadmapThemes
        XCTAssertEqual(themes.count, 3)
        let titles = themes.map(\.title)
        XCTAssertTrue(titles.contains(where: { $0.localizedCaseInsensitiveContains("Cross-platform") }))
        XCTAssertTrue(titles.contains(where: { $0.localizedCaseInsensitiveContains("Single codebase") }))
        XCTAssertTrue(titles.contains(where: { $0.localizedCaseInsensitiveContains("Community transparency") }))
    }

    func testCatalog_hasFiveSocialChannels() {
        let chs = ReleasesCatalog.socialChannels.map(\.name)
        for expected in ["Twitter", "YouTube", "Facebook", "Instagram", "Medium"] {
            XCTAssertTrue(chs.contains(expected), "Missing social channel \(expected)")
        }
    }

    func testCatalog_currentStableUpstreamMatchesSpec() {
        XCTAssertEqual(ReleasesCatalog.currentStableUpstreamVersion, "9.5.0.515")
    }
}
