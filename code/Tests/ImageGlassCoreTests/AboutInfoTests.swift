import XCTest
@testable import ImageGlassCore

/// Coverage for `AboutInfo` — the static data layer that backs the
/// SwiftUI About surface. We assert:
///   1. Required text fields are non-empty (project name, tagline,
///      copyright, philosophy lines, license summary).
///   2. License is GPLv3-derived (short name + canonical URL host).
///   3. Every URL field is well-formed and uses an expected scheme.
///   4. Upstream credit is preserved alongside the fork credit.
///   5. Donation channels include the channels named in the spec:
///      GitHub Sponsors, Patreon, PayPal, Stripe, OpenPledge.io.
///   6. Contact email is a syntactically valid `mailto:` URL.
final class AboutInfoTests: XCTestCase {

    // MARK: - Basic non-emptiness

    func testCoreStringFieldsAreNonEmpty() {
        XCTAssertFalse(AboutInfo.projectName.isEmpty)
        XCTAssertFalse(AboutInfo.upstreamProjectName.isEmpty)
        XCTAssertFalse(AboutInfo.tagline.isEmpty)
        XCTAssertFalse(AboutInfo.copyright.isEmpty)
        XCTAssertFalse(AboutInfo.maintainerQuote.isEmpty)
        XCTAssertFalse(AboutInfo.contactEmail.isEmpty)
    }

    func testCopyrightIncludesUpstreamRange() {
        // The spec pins the year range; if upstream rolls forward the
        // string here must be updated. We assert the lower bound and
        // current upper bound from the spec.
        XCTAssertTrue(AboutInfo.copyright.contains("2010"))
        XCTAssertTrue(AboutInfo.copyright.contains("2026"))
        // En-dash, per the spec line "Copyright … 2010–2026".
        XCTAssertTrue(AboutInfo.copyright.contains("2010–2026"))
    }

    func testPhilosophyHasThreePrinciples() {
        XCTAssertEqual(AboutInfo.philosophy.count, 3,
                       "Spec lists three principles: open source, ad-free, community-funded.")
        for line in AboutInfo.philosophy {
            XCTAssertFalse(line.isEmpty)
        }
        let joined = AboutInfo.philosophy.joined(separator: " ").lowercased()
        XCTAssertTrue(joined.contains("open source"))
        XCTAssertTrue(joined.contains("ad-free"))
        XCTAssertTrue(joined.contains("community-funded"))
    }

    // MARK: - Credits

    func testUpstreamCreatorIsDuongDieuPhap() {
        XCTAssertEqual(AboutInfo.upstreamCreator.name, "Dương Diệu Pháp")
        XCTAssertFalse(AboutInfo.upstreamCreator.role.isEmpty)
        XCTAssertFalse(AboutInfo.upstreamCreator.detail.isEmpty)
        XCTAssertEqual(AboutInfo.upstreamCreator.contactEmail, "phap@imageglass.org")
    }

    func testForkMaintainerIsBryanStarbuckAndPreservesUpstream() {
        XCTAssertEqual(AboutInfo.forkMaintainer.name, "Bryan Starbuck")
        XCTAssertFalse(AboutInfo.forkMaintainer.detail.isEmpty)

        // The fork credit must NOT erase upstream credit — both belong
        // on the About surface. Verify the fork blurb references the
        // upstream by name OR by the word "fork of … ImageGlass".
        let detail = AboutInfo.forkMaintainer.detail.lowercased()
        XCTAssertTrue(detail.contains("fork"),
                      "Fork credit should announce itself as a fork.")
        XCTAssertTrue(detail.contains("imageglass"),
                      "Fork credit should name the upstream project.")

        // Fork-specific feature list called out in the prompt.
        XCTAssertTrue(detail.contains("mcp"))
        XCTAssertTrue(detail.contains("panels"))
        XCTAssertTrue(detail.contains("scopes"))
        XCTAssertTrue(detail.contains("local storage"))
    }

    // MARK: - License

    func testLicenseIsGPLv3Derived() {
        XCTAssertEqual(AboutInfo.licenseShortName, "GPLv3")
        XCTAssertTrue(
            AboutInfo.licenseFullName.contains("GNU General Public License"),
            "Full name should identify the GPL."
        )
        XCTAssertTrue(
            AboutInfo.licenseFullName.contains("3"),
            "Full name should identify version 3."
        )

        XCTAssertEqual(AboutInfo.licenseURL.scheme, "https")
        XCTAssertEqual(AboutInfo.licenseURL.host, "www.gnu.org")
        XCTAssertTrue(
            AboutInfo.licenseURL.path.contains("gpl-3.0"),
            "License URL should point at the GPLv3 page."
        )

        let summary = AboutInfo.licenseSummary.lowercased()
        XCTAssertTrue(summary.contains("free software"))
        XCTAssertTrue(summary.contains("gnu general public license"))
        XCTAssertTrue(summary.contains("without any warranty"))
    }

    // MARK: - URLs are well-formed

    func testAllProjectLinkURLsAreWellFormedHTTPS() {
        XCTAssertFalse(AboutInfo.projectLinks.isEmpty)
        for link in AboutInfo.projectLinks {
            assertWellFormedHTTPS(link.url, label: link.title)
            XCTAssertFalse(link.title.isEmpty)
            XCTAssertFalse(link.subtitle.isEmpty)
        }
    }

    func testDonationChannelsCoverAllSpecChannels() {
        let titles = AboutInfo.donationChannels.map(\.title)
        for expected in [
            "GitHub Sponsors",
            "Patreon",
            "PayPal",
            "Stripe",
            "OpenPledge.io"
        ] {
            XCTAssertTrue(
                titles.contains(expected),
                "Missing donation channel: \(expected). Got: \(titles)"
            )
        }
        for link in AboutInfo.donationChannels {
            assertWellFormedHTTPS(link.url, label: link.title)
            XCTAssertFalse(link.subtitle.isEmpty)
        }
    }

    func testProjectLinksIncludeUpstreamGitHubAndWebsite() {
        let hosts = AboutInfo.projectLinks.compactMap(\.url.host)
        XCTAssertTrue(hosts.contains("imageglass.org"),
                      "Upstream website must be linked.")
        XCTAssertTrue(hosts.contains("github.com"),
                      "Upstream GitHub repo must be linked.")
    }

    // MARK: - Contact email

    func testContactEmailIsValidMailto() {
        // Trivial well-formedness: one `@`, non-empty local part, host
        // with a dot. Anything stricter belongs in an integration test,
        // not a unit test.
        let email = AboutInfo.contactEmail
        let parts = email.split(separator: "@")
        XCTAssertEqual(parts.count, 2, "Email must have exactly one '@'")
        XCTAssertFalse(parts[0].isEmpty)
        XCTAssertTrue(parts[1].contains("."), "Email host must contain a dot")

        XCTAssertEqual(AboutInfo.contactMailtoURL.scheme, "mailto")
        XCTAssertTrue(
            AboutInfo.contactMailtoURL.absoluteString.contains(email),
            "mailto: URL must embed the contact email."
        )
    }

    // MARK: - Helpers

    private func assertWellFormedHTTPS(_ url: URL, label: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertEqual(url.scheme, "https",
                       "\(label) must be https", file: file, line: line)
        XCTAssertNotNil(url.host,
                        "\(label) must have a host", file: file, line: line)
        XCTAssertFalse(url.host?.isEmpty ?? true,
                       "\(label) host must be non-empty", file: file, line: line)
        // Re-parse via URLComponents as an extra well-formedness check.
        XCTAssertNotNil(URLComponents(url: url, resolvingAgainstBaseURL: false),
                        "\(label) URL must be parseable", file: file, line: line)
    }
}
