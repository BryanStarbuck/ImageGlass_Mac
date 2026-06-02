import XCTest
@testable import ImageGlassCore

/// Exercises the four pieces filled in for the §1–§11 walkthrough:
/// - `select_file` writes `selection.txt` AND emits a
///   `notifications/imageglass/selection_changed` push event on the
///   `MCPNotificationBus`.
/// - `panel.set_view_mode` validates + writes `panel_view_mode.txt`
///   AND emits a `notifications/imageglass/view_mode_changed` event.
/// - The structured `log.log` line format for both tools.
/// - Invalid input lands `ok=false err=…` lines and emits no
///   notification.
///
/// Each test isolates its on-disk surface so the user's real
/// `~/Library/Application Support/ImageGlass_Mac/` is never touched.
final class FilePanelBridgeTests: XCTestCase {

    private var tmp: URL!
    private var logFile: URL!
    private var logger: MCPAuditLogger!
    private var bus: MCPNotificationBus!
    private var tools: FilePanelBridgeMCPTools!
    private var capturedNotes: [(String, [String: Any])] = []
    private var subscription: UUID?

    override func setUpWithError() throws {
        tmp = try makeTempDir()
        // Redirect AppPaths.macAppSupportDir into the temp dir by binding
        // HOME — every helper that resolves through `homeDirectory`
        // follows along.
        setenv("HOME", tmp.path, 1)

        logFile = tmp.appendingPathComponent("log.log")
        logger = MCPAuditLogger(overrideLogFile: logFile)
        bus = MCPNotificationBus()
        tools = FilePanelBridgeMCPTools(logger: logger, notifier: bus)

        capturedNotes.removeAll()
        subscription = bus.addSubscriber { [weak self] note in
            self?.capturedNotes.append((note.method, note.params))
        }
    }

    override func tearDownWithError() throws {
        if let sub = subscription {
            bus.removeSubscriber(sub)
            subscription = nil
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - select_file

    func testSelectFile_writesSelectionTxt_emitsNotification_logsCall() throws {
        let target = tmp.appendingPathComponent("Pictures/tour/beach/001.jpg").path
        let result = try tools.call(name: "select_file", arguments: [
            "path":   target,
            "client": "claude-code",
        ])
        XCTAssertNotEqual(result.isError, true)

        // selection.txt holds the resolved path.
        let selectionFile = AppPaths.macAppSupportDir
            .appendingPathComponent("selection.txt")
        let onDisk = try String(contentsOf: selectionFile, encoding: .utf8)
        XCTAssertEqual(onDisk, target)

        // The notification bus received a single selection_changed.
        let selectionEvents = capturedNotes.filter {
            $0.0 == "notifications/imageglass/selection_changed"
        }
        XCTAssertEqual(selectionEvents.count, 1)
        XCTAssertEqual(selectionEvents.first?.1["path"] as? String, target)

        // log.log includes the structured tool line.
        let log = try readLog()
        XCTAssertTrue(log.contains("tool=mcp.select_file"))
        XCTAssertTrue(log.contains("client=claude-code"))
        XCTAssertTrue(log.contains("ok=true"))
    }

    func testSelectFile_missingPath_logsFailure_andEmitsNothing() throws {
        let result = try tools.call(name: "select_file", arguments: [
            "client": "claude-code",
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(try readLog().contains("err=missing_path"))
        XCTAssertTrue(capturedNotes.isEmpty)
    }

    // MARK: - panel.set_view_mode

    func testSetViewMode_writesHintFile_emitsNotification_logsCall() throws {
        let result = try tools.call(name: "panel.set_view_mode", arguments: [
            "mode":   "tree",
            "client": "claude-code",
        ])
        XCTAssertNotEqual(result.isError, true)

        let modeFile = AppPaths.macAppSupportDir
            .appendingPathComponent("panel_view_mode.txt")
        let onDisk = try String(contentsOf: modeFile, encoding: .utf8)
        XCTAssertEqual(onDisk, "tree")

        let viewModeEvents = capturedNotes.filter {
            $0.0 == "notifications/imageglass/view_mode_changed"
        }
        XCTAssertEqual(viewModeEvents.count, 1)
        XCTAssertEqual(viewModeEvents.first?.1["mode"] as? String, "tree")

        let log = try readLog()
        XCTAssertTrue(log.contains("tool=mcp.panel.set_view_mode"))
        XCTAssertTrue(log.contains("mode=tree"))
        XCTAssertTrue(log.contains("ok=true"))
    }

    func testSetViewMode_invalidMode_logsFailure_andEmitsNothing() throws {
        let result = try tools.call(name: "panel.set_view_mode", arguments: [
            "mode": "bogus",
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(try readLog().contains("err=invalid_mode"))
        XCTAssertTrue(capturedNotes.isEmpty)
    }

    // MARK: - MCPNotificationBus subscriber lifecycle

    func testNotificationBus_addAndRemoveSubscriber() {
        let isolated = MCPNotificationBus()
        var fired = 0
        let token = isolated.addSubscriber { _ in fired += 1 }
        isolated.emitSelectionChanged(path: "/x.jpg")
        XCTAssertEqual(fired, 1)
        isolated.removeSubscriber(token)
        isolated.emitSelectionChanged(path: "/y.jpg")
        XCTAssertEqual(fired, 1, "removed subscriber must not receive further events")
    }

    func testNotificationBus_emitAutoSelectFirst_carriesCorrAndReason() {
        let isolated = MCPNotificationBus()
        var received: MCPNotificationBus.Notification?
        _ = isolated.addSubscriber { received = $0 }
        isolated.emitAutoSelectFirst(
            path: "/beach/001.jpg",
            corr: "ab12cd34",
            reason: "viewer_empty"
        )
        XCTAssertEqual(received?.method, "notifications/imageglass/auto_select_first")
        XCTAssertEqual(received?.params["path"] as? String, "/beach/001.jpg")
        XCTAssertEqual(received?.params["corr"] as? String, "ab12cd34")
        XCTAssertEqual(received?.params["reason"] as? String, "viewer_empty")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("file-panel-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readLog() throws -> String {
        guard FileManager.default.fileExists(atPath: logFile.path) else { return "" }
        let data = try Data(contentsOf: logFile)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
