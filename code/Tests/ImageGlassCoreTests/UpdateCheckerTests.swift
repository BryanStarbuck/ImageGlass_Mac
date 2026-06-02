import XCTest
@testable import ImageGlassCore

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Policy

    func testIsDisabledByDefault_preservesPrivacy() {
        XCTAssertFalse(UpdateChecker.isEnabledByDefault,
                       "Update check must be disabled by default per privacy policy")
        let checker = UpdateChecker()
        XCTAssertFalse(checker.isEnabled)
    }

    func testCheck_throwsDisabledByPolicy_whenNotForced() async {
        let checker = UpdateChecker(isEnabled: false)
        do {
            _ = try await checker.check(force: false)
            XCTFail("Expected disabledByPolicy")
        } catch let e as UpdateCheckError {
            XCTAssertEqual(e, .disabledByPolicy)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Endpoint routing

    func testEndpointURL_stableChannelUsesLatestEndpoint() {
        let checker = UpdateChecker(channel: .stable)
        XCTAssertEqual(
            checker.endpointURL.absoluteString,
            "https://api.github.com/repos/ACT3ai/ImageGlass_Mac/releases/latest"
        )
    }

    func testEndpointURL_betaChannelUsesFullReleasesList() {
        let checker = UpdateChecker(channel: .beta)
        XCTAssertEqual(
            checker.endpointURL.absoluteString,
            "https://api.github.com/repos/ACT3ai/ImageGlass_Mac/releases"
        )
    }

    // MARK: - Tag normalization

    func testNormalize_stripsLeadingV() {
        XCTAssertEqual(UpdateChecker.normalize(tag: "v0.2.0"), "0.2.0")
        XCTAssertEqual(UpdateChecker.normalize(tag: "V1.0.0"), "1.0.0")
        XCTAssertEqual(UpdateChecker.normalize(tag: "0.2.0"), "0.2.0")
        XCTAssertEqual(UpdateChecker.normalize(tag: "0.2.0-beta"), "0.2.0-beta")
    }

    // MARK: - Version comparison

    func testIsNewer_higherMinor() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
    }

    func testIsNewer_equalVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
    }

    func testIsNewer_olderVersion() {
        XCTAssertFalse(UpdateChecker.isNewer("0.0.9", than: "0.1.0"))
    }

    func testIsNewer_nilCandidate() {
        XCTAssertFalse(UpdateChecker.isNewer(nil, than: "0.1.0"))
    }

    func testIsNewer_preReleaseTreatedAsEqual_notNewer() {
        // 0.2.0-beta is not newer than 0.2.0 of the same numeric triple.
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0-beta", than: "0.2.0"))
    }

    func testIsNewer_buildMetadataIgnored() {
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0+5", than: "0.1.0+2"))
    }

    // MARK: - JSON parsing

    func testParseLatest_singleObjectShape() throws {
        let json = """
        {
            "tag_name": "v0.5.0",
            "html_url": "https://github.com/ACT3ai/ImageGlass_Mac/releases/tag/v0.5.0",
            "published_at": "2026-06-01T12:00:00Z",
            "prerelease": false,
            "draft": false
        }
        """
        let data = Data(json.utf8)
        let r = try UpdateChecker.parseLatest(data: data, channel: .stable)
        XCTAssertEqual(r?.version, "0.5.0")
        XCTAssertNotNil(r?.publishedAt)
        XCTAssertEqual(r?.htmlURL?.absoluteString,
                       "https://github.com/ACT3ai/ImageGlass_Mac/releases/tag/v0.5.0")
    }

    func testParseLatest_arrayShape_skipsPreReleasesOnStableChannel() throws {
        let json = """
        [
            { "tag_name": "v0.6.0-beta", "prerelease": true, "draft": false },
            { "tag_name": "v0.5.0", "prerelease": false, "draft": false }
        ]
        """
        let data = Data(json.utf8)
        let r = try UpdateChecker.parseLatest(data: data, channel: .stable)
        XCTAssertEqual(r?.version, "0.5.0")
    }

    func testParseLatest_arrayShape_acceptsPreReleaseOnBetaChannel() throws {
        let json = """
        [
            { "tag_name": "v0.6.0-beta", "prerelease": true, "draft": false },
            { "tag_name": "v0.5.0", "prerelease": false, "draft": false }
        ]
        """
        let data = Data(json.utf8)
        let r = try UpdateChecker.parseLatest(data: data, channel: .beta)
        XCTAssertEqual(r?.version, "0.6.0-beta")
    }

    func testParseLatest_skipsDrafts() throws {
        let json = """
        [
            { "tag_name": "v0.7.0", "prerelease": false, "draft": true },
            { "tag_name": "v0.5.0", "prerelease": false, "draft": false }
        ]
        """
        let data = Data(json.utf8)
        let r = try UpdateChecker.parseLatest(data: data, channel: .stable)
        XCTAssertEqual(r?.version, "0.5.0")
    }
}
