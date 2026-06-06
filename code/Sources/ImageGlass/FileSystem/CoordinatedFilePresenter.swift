// CoordinatedFilePresenter.swift
//
// Implements spec §3.2 tertiary mechanism (NSFilePresenter) for the
// currently-displayed file. The presenter cooperates with document-
// based apps that use NSFileCoordinator (Preview, TextEdit, Pages,
// other Apple-aware editors) so we can:
//
//   * pause `FocusedFileWatcher` while a coordinated writer holds the
//     file (spec §7.13 — avoids torn reads of a half-written save),
//   * react to `presentedItemDidChange()` for cooperating writers
//     who do not bypass coordination,
//   * react to `presentedItemDidMove(to:)` so the viewer follows the
//     file to its new location without a stale path.
//
// Non-coordinating writers (mv, cp, rsync, git, Lightroom, Photoshop
// in many configurations, etc.) bypass this entirely and are picked
// up by `FocusedFileWatcher`'s kqueue or `FSEventsScopeWatcher`.

import Foundation
import ImageGlassCore

final class CoordinatedFilePresenter: NSObject, NSFilePresenter {

    /// Called when a coordinated writer takes the file. The
    /// `FocusedFileWatcher`'s `paused` flag is flipped on so we
    /// don't react to mid-write events.
    var onWriterAcquired: (() -> Void)?
    /// Called when the writer relinquishes. The watcher resumes and
    /// emits whatever the file looks like now.
    var onWriterReleased: (() -> Void)?
    /// Called on `presentedItemDidChange()` — equivalent to a
    /// `.modified` for our purposes.
    var onChange: ((URL) -> Void)?
    /// Called on `presentedItemDidMove(to:)` — equivalent to
    /// `.renamed`.
    var onMove: ((_ from: URL, _ to: URL) -> Void)?

    private var url: URL?

    /// NSFilePresenter protocol — Apple delivers callbacks on this
    /// queue. Max concurrent operations 1 so we serialize against
    /// our own bookkeeping.
    let presentedItemOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "io.imageglass.presenter"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .default
        return q
    }()

    private(set) var presentedItemURL: URL?

    /// Swap the file being presented. Passing nil unregisters.
    func setURL(_ newURL: URL?) {
        if let current = url {
            NSFileCoordinator.removeFilePresenter(self)
            _ = current
        }
        url = newURL
        presentedItemURL = newURL
        if newURL != nil {
            NSFileCoordinator.addFilePresenter(self)
        }
    }

    // MARK: - NSFilePresenter

    func relinquishPresentedItem(toWriter writer: @escaping ((() -> Void)?) -> Void) {
        // Spec §7.13: pause the focused-file watcher; wait for the
        // writer to call our reacquire closure.
        onWriterAcquired?()
        writer { [weak self] in
            self?.onWriterReleased?()
        }
    }

    func presentedItemDidChange() {
        if let url = url {
            onChange?(url)
        }
    }

    func presentedItemDidMove(to newURL: URL) {
        let old = url ?? newURL
        url = newURL
        presentedItemURL = newURL
        onMove?(old, newURL)
    }

    /// Apple-recommended: tell the OS our file went away so it stops
    /// asking us about it. The viewer's `.removed` reaction is
    /// handled by `FocusedFileWatcher` + scope watcher anyway.
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }
}
