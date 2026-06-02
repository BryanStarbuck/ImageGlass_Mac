import XCTest
@testable import ImageGlassCore

final class AppVersionTests: XCTestCase {

    func testMarketingVersion_isSemverTriple() {
        let v = AppVersion.marketingVersion
        let parts = v.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "marketingVersion must be MAJOR.MINOR.PATCH; got \(v)")
        for p in parts {
            XCTAssertNotNil(Int(p), "marketingVersion component '\(p)' must be numeric")
        }
    }

    func testBuildNumber_isPositive() {
        XCTAssertGreaterThan(AppVersion.buildNumber, 0)
    }

    func testSemverString_includesChannelForPreReleases() {
        switch AppVersion.channel {
        case .stable:
            XCTAssertFalse(AppVersion.semverString.contains("-"),
                           "stable semverString must not embed a pre-release suffix")
        case .beta, .dev:
            XCTAssertTrue(AppVersion.semverString.contains("-\(AppVersion.channel.rawValue)"),
                          "non-stable semverString must embed channel as pre-release")
        }
        XCTAssertTrue(AppVersion.semverString.contains("+\(AppVersion.buildNumber)"),
                      "semverString must embed buildNumber as build metadata")
    }

    func testUserAgent_identifiesMacFork() {
        XCTAssertTrue(AppVersion.userAgent.contains("ImageGlass_Mac"))
        XCTAssertTrue(AppVersion.userAgent.contains(AppVersion.semverString))
    }

    func testCatalogVersionLabel_isUsedInCatalog() {
        let label = AppVersion.catalogVersionLabel
        XCTAssertTrue(label.hasPrefix("ImageGlass_Mac "))
        let macForkVersions = ReleasesCatalog.releases
            .filter { $0.origin == .macFork }
            .map(\.version)
        XCTAssertTrue(
            macForkVersions.contains(label),
            "AppVersion.catalogVersionLabel (\(label)) must appear as a Mac fork entry in the catalog"
        )
    }

    func testReleaseChannel_displayLabel() {
        XCTAssertEqual(ReleaseChannel.stable.displayLabel, "Stable")
        XCTAssertEqual(ReleaseChannel.beta.displayLabel, "Beta")
        XCTAssertEqual(ReleaseChannel.dev.displayLabel, "Dev")
    }

    func testReleaseChannel_githubReleasesPath_stable_usesLatest() {
        XCTAssertEqual(ReleaseChannel.stable.githubReleasesPath, "releases/latest")
        XCTAssertEqual(ReleaseChannel.beta.githubReleasesPath, "releases")
        XCTAssertEqual(ReleaseChannel.dev.githubReleasesPath, "releases")
    }
}
