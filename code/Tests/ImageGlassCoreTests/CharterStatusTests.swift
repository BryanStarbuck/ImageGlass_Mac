import XCTest
@testable import ImageGlassCore

/// Charter-level audit tests. These check that the five load-bearing
/// goals listed in `docs/overview.mdx` are still wired through the
/// public Core API — not the polish of any one subsystem.
final class CharterStatusTests: XCTestCase {

    func testReportCoversAllFiveGoals() {
        let report = CharterStatus.report()
        XCTAssertEqual(report.goals.count, CharterGoal.allCases.count)
        for goal in CharterGoal.allCases {
            XCTAssertNotNil(report.status(for: goal),
                            "Charter status report is missing goal \(goal).")
        }
    }

    func testNoGoalIsSilentlyMissing() {
        let report = CharterStatus.report()
        for entry in report.goals {
            XCTAssertNotEqual(entry.state, .missing,
                              "Charter goal #\(entry.goal.index) '\(entry.goal.title)' is missing: \(entry.openGaps.joined(separator: "; "))")
        }
        XCTAssertTrue(report.allGoalsPresent)
    }

    func testEveryGoalCarriesEvidence() {
        let report = CharterStatus.report()
        for entry in report.goals {
            XCTAssertFalse(entry.evidence.isEmpty,
                           "Goal '\(entry.goal.title)' has no evidence — audit cannot show its reasoning.")
        }
    }

    func testMCPDrivenEditingExposesRequiredTools() {
        // MCP-driven editing is the load-bearing contract for Claude Code.
        // Every required tool MUST be advertised — anything less breaks
        // overview.mdx §5.
        let advertised = Set(MCPTools().descriptors().map { $0.name })
        let required: [String] = [
            "list_scopes",
            "get_scope",
            "create_scope",
            "set_directories",
            "set_include_criteria",
            "set_exclude_criteria",
            "evaluate_scope",
            "delete_scope",
        ]
        for name in required {
            XCTAssertTrue(advertised.contains(name),
                          "Required MCP tool '\(name)' is missing — charter goal #5 broken.")
        }
    }

    func testCharterStatusToolIsAdvertisedAndCallable() throws {
        let tools = MCPTools()
        let advertised = tools.descriptors().map { $0.name }
        XCTAssertTrue(advertised.contains("charter_status"))

        let result = try tools.call(name: "charter_status", arguments: [:])
        XCTAssertFalse(result.isError ?? false)
        let body = result.content.first?.text ?? ""
        // The serialized JSON should mention each goal raw value.
        for goal in CharterGoal.allCases {
            XCTAssertTrue(body.contains(goal.rawValue),
                          "charter_status output is missing goal \(goal.rawValue).")
        }
    }

    func testSummaryIsHumanReadable() {
        let s = CharterStatus.summary()
        XCTAssertTrue(s.contains("charter"))
        XCTAssertTrue(s.contains("\(CharterGoal.allCases.count)"))
    }

    func testTopLevelImageGlassCoreSurface() {
        // The `ImageGlassCore.charterStatus()` entry point is the public
        // shorthand the app + MCP server are encouraged to call.
        let report = ImageGlassCore.charterStatus()
        XCTAssertEqual(report.goals.count, CharterGoal.allCases.count)
        XCTAssertFalse(ImageGlassCore.charterSummary().isEmpty)
    }

    func testScopeControlsSelfCheckActuallyRunsTheWalker() {
        // The scope-controls evaluator was upgraded from a type-shape check
        // into an actual evaluator round-trip on a scratch directory. If the
        // include/exclude semantics ever silently regress, this status should
        // drop out of `implemented`.
        let report = CharterStatus.report()
        let entry = report.status(for: .scopeControls)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.state, .implemented,
                       "scope-controls walker self-check failed: \(entry?.openGaps.joined(separator: "; ") ?? "")")
        let evidence = entry?.evidence.joined(separator: " | ") ?? ""
        XCTAssertTrue(evidence.contains("self-check"),
                      "scope-controls evidence should record that the walker self-check ran.")
    }

    func testLocalStorageSelfCheckRoundTripsScope() {
        // The local-storage evaluator now exercises the JSON round-trip for
        // a synthetic scope so the plain-text contract is protected from
        // silent Codable regressions.
        let report = CharterStatus.report()
        let entry = report.status(for: .localStorage)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.state, .implemented,
                       "local-storage round-trip self-check failed: \(entry?.openGaps.joined(separator: "; ") ?? "")")
        let evidence = entry?.evidence.joined(separator: " | ") ?? ""
        XCTAssertTrue(evidence.contains("round-trip"),
                      "local-storage evidence should record that the codable round-trip self-check ran.")
    }

    func testReportIsRoundTripCodable() throws {
        let report = CharterStatus.report()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(report)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(CharterStatusReport.self, from: data)
        XCTAssertEqual(decoded.goals.count, report.goals.count)
        for goal in CharterGoal.allCases {
            XCTAssertEqual(decoded.status(for: goal)?.state,
                           report.status(for: goal)?.state)
        }
    }
}
