import XCTest
@testable import ImageGlassCore

final class CLIArgumentsTests: XCTestCase {

    // MARK: program-name handling

    func testSkipsProgramNameByDefault() {
        let a = ImageGlassLaunchArguments.parse(["/Applications/ImageGlass.app/Contents/MacOS/ImageGlass"])
        XCTAssertEqual(a.overrides, [:])
        XCTAssertEqual(a.openPaths, [])
        XCTAssertFalse(a.startupBoost)
    }

    func testKeepsProgramNameWhenAsked() {
        let a = ImageGlassLaunchArguments.parse(["foo"], skipProgramName: false)
        // "foo" is a positional path because it has no leading slash.
        XCTAssertEqual(a.openPaths, ["foo"])
    }

    // MARK: /Name=Value overrides

    func testSingleSettingOverride() {
        let a = ImageGlassLaunchArguments.parse(["prog", "/ShowToolbar=false"])
        XCTAssertEqual(a.overrides, ["ShowToolbar": "false"])
        XCTAssertEqual(a.openPaths, [])
    }

    func testMultipleOverridesPreserveAllKeys() {
        let a = ImageGlassLaunchArguments.parse([
            "prog",
            "/ShowToolbar=false",
            "/ShowGallery=false",
            "/WindowBackdrop=Acrylic",
        ])
        XCTAssertEqual(a.overrides["ShowToolbar"], "false")
        XCTAssertEqual(a.overrides["ShowGallery"], "false")
        XCTAssertEqual(a.overrides["WindowBackdrop"], "Acrylic")
        XCTAssertEqual(a.overrides.count, 3)
    }

    func testQuotedValueIsUnwrapped() {
        let a = ImageGlassLaunchArguments.parse([
            "prog",
            "/WindowBackdrop=\"Acrylic\"",
        ])
        XCTAssertEqual(a.overrides["WindowBackdrop"], "Acrylic")
    }

    func testSingleQuotedValueIsUnwrapped() {
        let a = ImageGlassLaunchArguments.parse([
            "prog",
            "/Greeting='hello world'",
        ])
        XCTAssertEqual(a.overrides["Greeting"], "hello world")
    }

    func testDottedAndUnderscoredKeysAccepted() {
        let a = ImageGlassLaunchArguments.parse([
            "prog",
            "/ui.window.backdrop=Acrylic",
            "/feature_flag_x=on",
        ])
        XCTAssertEqual(a.overrides["ui.window.backdrop"], "Acrylic")
        XCTAssertEqual(a.overrides["feature_flag_x"], "on")
    }

    func testEmptyValueAllowed() {
        let a = ImageGlassLaunchArguments.parse(["prog", "/X="])
        XCTAssertEqual(a.overrides["X"], "")
    }

    // MARK: positional file paths

    func testAbsolutePathTreatedAsFileNotOverride() {
        // `/Users/...` looks like an override-prefix but the segment after `/`
        // is not a valid setting name, so we must classify it as a path.
        let a = ImageGlassLaunchArguments.parse(["prog", "/Users/me/photo.jpg"])
        XCTAssertEqual(a.openPaths, ["/Users/me/photo.jpg"])
        XCTAssertEqual(a.overrides, [:])
    }

    func testRelativePathTreatedAsFile() {
        let a = ImageGlassLaunchArguments.parse(["prog", "photo.jpg", "another/file.png"])
        XCTAssertEqual(a.openPaths, ["photo.jpg", "another/file.png"])
    }

    func testQuotedPathIsUnwrapped() {
        let a = ImageGlassLaunchArguments.parse(["prog", "\"/Users/me/my photos/sky.jpg\""])
        XCTAssertEqual(a.openPaths, ["/Users/me/my photos/sky.jpg"])
    }

    // MARK: mixed input matching the spec example

    func testSpecExample() {
        // From docs/command-line.mdx:
        // ImageGlass.exe /ShowToolbar=false /ShowGallery=false /WindowBackdrop="Acrylic" "C:\my photos\sky.jpg"
        let a = ImageGlassLaunchArguments.parse([
            "ImageGlass",
            "/ShowToolbar=false",
            "/ShowGallery=false",
            "/WindowBackdrop=\"Acrylic\"",
            "/Users/me/my photos/sky.jpg",
        ])
        XCTAssertEqual(a.overrides, [
            "ShowToolbar": "false",
            "ShowGallery": "false",
            "WindowBackdrop": "Acrylic",
        ])
        XCTAssertEqual(a.openPaths, ["/Users/me/my photos/sky.jpg"])
    }

    // MARK: startup-boost flag

    func testStartupBoostFlag() {
        let a = ImageGlassLaunchArguments.parse(["prog", "--startup-boost"])
        XCTAssertTrue(a.startupBoost)
        XCTAssertEqual(a.overrides, [:])
        XCTAssertEqual(a.openPaths, [])
    }

    func testStartupBoostAlongsideOverridesAndPaths() {
        let a = ImageGlassLaunchArguments.parse([
            "prog",
            "--startup-boost",
            "/ShowToolbar=false",
            "photo.jpg",
        ])
        XCTAssertTrue(a.startupBoost)
        XCTAssertEqual(a.overrides, ["ShowToolbar": "false"])
        XCTAssertEqual(a.openPaths, ["photo.jpg"])
    }

    // MARK: name-validation helper

    func testSettingNameValidation() {
        XCTAssertTrue(ImageGlassLaunchArguments.isValidSettingName("ShowToolbar"))
        XCTAssertTrue(ImageGlassLaunchArguments.isValidSettingName("ui.window.backdrop"))
        XCTAssertTrue(ImageGlassLaunchArguments.isValidSettingName("a_b_1"))
        XCTAssertFalse(ImageGlassLaunchArguments.isValidSettingName(""))
        XCTAssertFalse(ImageGlassLaunchArguments.isValidSettingName("Users/me"))
        XCTAssertFalse(ImageGlassLaunchArguments.isValidSettingName("with space"))
    }
}
