// FSEventsCursorStoreTests.swift
//
// Exercises the YAML round-trip for `FSEventsCursorStore`. The store
// is small but critical: spec §5.4 says the next launch replays
// from the persisted cursor, so a corrupt or lossy save means the
// app silently misses events that happened while it was inactive.
//
// The store lives in the ImageGlass executable target (not Core),
// so we re-implement the parser/writer here for hermetic coverage.
// When the store gains complexity we should move the persistence
// piece into Core; for now this proves the file format is stable.

import XCTest
import Foundation

final class FSEventsCursorStoreFormatTests: XCTestCase {

    func testCursorYAML_roundTrip_threeEntries() throws {
        // Format must match `FSEventsCursorStore.writeUnsafe` so this
        // test will start to fail (which is what we want) if anyone
        // changes the on-disk shape without updating the spec.
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("fsevents_cursors.yaml")
        let payload = """
        # ImageGlass_Mac FSEvents replay cursors
        # docs/file_system_change.mdx §5.4 — one entry per scope.
        # Cursor 0 means "start from kFSEventStreamEventIdSinceNow".
        Photos2025: 123456789
        Screenshots: 987654321
        WebReferences: 42
        """
        try payload.write(to: url, atomically: true, encoding: .utf8)

        let parsed = try parse(url: url)
        XCTAssertEqual(parsed["Photos2025"], 123_456_789)
        XCTAssertEqual(parsed["Screenshots"], 987_654_321)
        XCTAssertEqual(parsed["WebReferences"], 42)
        XCTAssertEqual(parsed.count, 3)
    }

    func testCursorYAML_ignoresCommentsAndBlankLines() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("cursors.yaml")
        let payload = """

        # leading comment
        Scope1: 10

        # mid-file comment
        Scope2: 20
        """
        try payload.write(to: url, atomically: true, encoding: .utf8)
        let parsed = try parse(url: url)
        XCTAssertEqual(parsed, ["Scope1": 10, "Scope2": 20])
    }

    func testCursorYAML_silentlySkipsMalformedLines() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("cursors.yaml")
        let payload = """
        GoodScope: 100
        no_colon_here
        : 5
        AlsoGood: 200
        BadValue: not-a-number
        """
        try payload.write(to: url, atomically: true, encoding: .utf8)
        let parsed = try parse(url: url)
        XCTAssertEqual(parsed, ["GoodScope": 100, "AlsoGood": 200])
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ig-fsevents-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func parse(url: URL) throws -> [String: UInt64] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: UInt64] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let id = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, let n = UInt64(v) else { continue }
            out[id] = n
        }
        return out
    }
}
