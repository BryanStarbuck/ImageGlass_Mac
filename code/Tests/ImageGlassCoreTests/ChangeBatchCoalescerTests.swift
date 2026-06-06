// ChangeBatchCoalescerTests.swift
//
// Exercises every rule in docs/file_system_change.mdx §5.2 by feeding
// synthetic event sequences into `ChangeBatchCoalescer.coalesce(_:)`.
// These are the same rules the FSEvents path runs against real kernel
// events, so the production watcher is covered by the same logic the
// tests pin here.

import XCTest
@testable import ImageGlassCore

final class ChangeBatchCoalescerTests: XCTestCase {

    private let fileA = URL(fileURLWithPath: "/tmp/imageglass-tests/a.jpg")
    private let fileB = URL(fileURLWithPath: "/tmp/imageglass-tests/b.jpg")

    // MARK: - Single-URL rules

    func testAdded_thenModified_collapsesToAdded() {
        let input: [ChangeEvent] = [
            .added(fileA, inode: 100),
            .modified(fileA, inode: 100),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, "added")
    }

    func testAdded_thenRemoved_collapsesToNothing() {
        let input: [ChangeEvent] = [
            .added(fileA, inode: 100),
            .removed(fileA, inode: 100),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out, [])
    }

    func testModifiedTwice_collapsesToOne() {
        let input: [ChangeEvent] = [
            .modified(fileA, inode: 100),
            .modified(fileA, inode: 100),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, "modified")
    }

    func testRemoved_thenAdded_sameInode_samePath_collapsesToModified() {
        // Spec §5.2: removed(inode=X) + added(inode=X) on the same URL
        // is the "in-place touch" pattern (same file, same inode, new
        // mtime). The coalescer surfaces it as a single .modified.
        let input: [ChangeEvent] = [
            .removed(fileA, inode: 100),
            .added(fileA, inode: 100),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, "modified")
    }

    func testRemoved_thenAdded_sameInode_differentPath_collapsesToRenamed() {
        // Spec §5.2: removed(inode=X) + added(inode=X) on different
        // URLs is the rename pattern.
        let input: [ChangeEvent] = [
            .removed(fileA, inode: 100),
            .added(fileB, inode: 100),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        guard case let .renamed(from, to, inode) = out[0] else {
            XCTFail("expected .renamed, got \(out[0])")
            return
        }
        XCTAssertEqual(from, fileA)
        XCTAssertEqual(to, fileB)
        XCTAssertEqual(inode, 100)
    }

    func testRemoved_thenAdded_differentInode_treatedAsRealReplace() {
        // Spec §5.2 + §7.16 inode-reuse guard: when inodes differ
        // we must NOT collapse to .modified — these are genuinely
        // distinct files at the same path.
        let input: [ChangeEvent] = [
            .removed(fileA, inode: 100),
            .added(fileA, inode: 200),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        // Last-write-wins keeps the .added.
        XCTAssertEqual(out.first?.kind, "added")
    }

    func testAttributesChanged_thenModified_collapsesToModified() {
        let input: [ChangeEvent] = [
            .attributesChanged(fileA),
            .modified(fileA, inode: 100),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, "modified")
    }

    func testModified_thenAttributesChanged_collapsesToModified() {
        let input: [ChangeEvent] = [
            .modified(fileA, inode: 100),
            .attributesChanged(fileA),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, "modified")
    }

    func testMaterialized_thenModified_collapsesToModified() {
        // iCloud placeholder materialization + subsequent modification
        // in the same window — the modify implies the materialization.
        let input: [ChangeEvent] = [
            .materialized(fileA),
            .modified(fileA, inode: 100),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, "modified")
    }

    // MARK: - Cross-URL ordering

    func testMultipleURLs_preserveFirstOccurrenceOrder() {
        let input: [ChangeEvent] = [
            .added(fileB, inode: 200),
            .modified(fileA, inode: 100),
            .modified(fileB, inode: 200),
            .modified(fileA, inode: 100),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 2)
        // fileB appeared first, so it leads.
        XCTAssertEqual(out[0].url, fileB)
        XCTAssertEqual(out[1].url, fileA)
    }

    // MARK: - Identity passes

    func testSingleEvent_passesThrough() {
        let input: [ChangeEvent] = [.modified(fileA, inode: nil)]
        XCTAssertEqual(ChangeBatchCoalescer.coalesce(input), input)
    }

    func testEmpty_returnsEmpty() {
        XCTAssertEqual(ChangeBatchCoalescer.coalesce([]), [])
    }

    // MARK: - Inode synthesis edge cases

    func testRemoved_thenAdded_nilInodes_doesNotSynthesizeRename() {
        // Without inode information we cannot prove these are the
        // same file. They remain two separate events.
        let input: [ChangeEvent] = [
            .removed(fileA, inode: nil),
            .added(fileB, inode: nil),
        ]
        let out = ChangeBatchCoalescer.coalesce(input)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].kind, "removed")
        XCTAssertEqual(out[1].kind, "added")
    }
}
