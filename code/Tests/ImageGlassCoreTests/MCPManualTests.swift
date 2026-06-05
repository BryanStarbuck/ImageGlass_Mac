import XCTest
@testable import ImageGlassCore

/// Spec `docs/use_cases/mcp_and_filters_on_dirs.mdx` §7.6 — the
/// manual must mention every MCP tool the server advertises, so the
/// LLM never sees a tool described in `tools/list` that lacks a
/// usage hint in the manual.
///
/// This is a guard rail: any PR that adds a tool but forgets to
/// update `mcp_manual.txt` fails the build here.
final class MCPManualTests: XCTestCase {

    func testManualBundledFromResource() {
        XCTAssertTrue(
            MCPManual.loadedFromResource,
            "MCPManual.text must come from the bundled mcp_manual.txt, " +
            "not the embedded stub fallback. If this fails, the SwiftPM " +
            "resource declaration in Package.swift is broken."
        )
        XCTAssertFalse(MCPManual.text.isEmpty)
    }

    func testManualMentionsEveryDirectoryTool() {
        // The manual is scoped to the directory + filter surface
        // (the subject of mcp_and_filters_on_dirs.mdx). Tools from
        // other subsystems (themes, crop, panels, charter, …) are
        // intentionally out of scope here. If you add a directory
        // tool, list it in mcp_manual.txt §1.
        let manual = MCPManual.text
        let directoryToolNames = DirectoriesMCPTools.toolNames.sorted()
        XCTAssertFalse(directoryToolNames.isEmpty)

        var missing: [String] = []
        for name in directoryToolNames where !manual.contains(name) {
            missing.append(name)
        }
        XCTAssertTrue(
            missing.isEmpty,
            "mcp_manual.txt does not mention these tools: " +
            "\(missing.joined(separator: ", ")). " +
            "Update mcp_manual.txt in the same PR that adds them."
        )
    }

    func testManualHasRequiredSectionHeaders() {
        // Spec §7.2 — the manual must teach the LLM what to call,
        // how voice verbs map to fields, and what priorities mean.
        // These three substrings are the minimum proof.
        let manual = MCPManual.text
        let required = [
            "Key Capabilities",
            "Verb → Field Cookbook",
            "Filter Items and Priorities",
        ]
        for header in required {
            XCTAssertTrue(
                manual.contains(header),
                "mcp_manual.txt is missing required section: '\(header)'"
            )
        }
    }

    func testResourceUriAndMetadataStable() {
        // Spec §7.5 — these are part of the public contract advertised
        // on `resources/list`. Changing them is a breaking change for
        // any client that has bookmarked the URI.
        XCTAssertEqual(MCPManual.resourceURI, "imageglass-mcp://manual")
        XCTAssertEqual(MCPManual.resourceMimeType, "text/plain")
        XCTAssertFalse(MCPManual.resourceName.isEmpty)
        XCTAssertFalse(MCPManual.resourceDescription.isEmpty)
    }
}
