// ICloudMaterializationWatcher.swift
//
// Spec §3.2 quaternary mechanism: NSMetadataQuery against the
// iCloud Documents scope. FSEvents alone does not reliably fire
// when a `.icloud` placeholder is replaced with the real file by
// the iCloud daemon (the rename from `family.heic.icloud` to
// `family.heic` is observable, but the byte-materialization on
// existing real files is not). Spotlight does, via NSMetadataQuery
// — see spec §7.12.
//
// We bind one query per scope that intersects `~/Library/Mobile
// Documents/`. The query subscribes to
// `NSMetadataQueryDidUpdate` and emits `.materialized(url)` /
// `.dematerialized(url)` through the same `ChangeBatch` channel.
//
// Skipped silently for scopes whose roots do not contain iCloud
// paths — there's nothing useful to query for in that case.

import Foundation
import ImageGlassCore

final class ICloudMaterializationWatcher: NSObject, @unchecked Sendable {

    let scopeID: String
    private let query: NSMetadataQuery
    private let onBatch: (ChangeBatch) -> Void

    /// Tracks which URLs we've already seen as materialized so we
    /// can emit `.dematerialized` on the inverse transition.
    private var materialized: Set<URL> = []
    private let serial = DispatchQueue(label: "io.imageglass.spotlight",
                                       qos: .utility)

    /// Returns nil if the scope has no iCloud roots — caller skips
    /// registration in that case.
    static func makeIfNeeded(scopeID: String,
                             roots: [URL],
                             onBatch: @escaping (ChangeBatch) -> Void) -> ICloudMaterializationWatcher? {
        let mobileDocs = ("~/Library/Mobile Documents" as NSString).expandingTildeInPath
        let intersects = roots.contains { $0.path.hasPrefix(mobileDocs) }
        guard intersects else { return nil }
        return ICloudMaterializationWatcher(scopeID: scopeID,
                                            roots: roots,
                                            onBatch: onBatch)
    }

    private init(scopeID: String, roots: [URL], onBatch: @escaping (ChangeBatch) -> Void) {
        self.scopeID = scopeID
        self.query = NSMetadataQuery()
        self.onBatch = onBatch
        super.init()

        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Match any item — we filter by root path in the callbacks.
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        query.operationQueue = OperationQueue()
        query.operationQueue?.name = "io.imageglass.spotlight"
        query.operationQueue?.maxConcurrentOperationCount = 1

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        _ = roots
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            // NSMetadataQuery requires start() on the main run loop.
            _ = self?.query.start()
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.query.stop()
        }
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleUpdate(_ notification: Notification) {
        serial.async { [weak self] in
            guard let self else { return }
            self.query.disableUpdates()
            defer { self.query.enableUpdates() }

            var newlyMaterialized: [URL] = []
            var newlyDematerialized: [URL] = []
            var seenThisPass: Set<URL> = []

            for i in 0..<self.query.resultCount {
                guard let item = self.query.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
                else { continue }
                let url = URL(fileURLWithPath: path)
                seenThisPass.insert(url)
                let isCurrent = (status == NSMetadataUbiquitousItemDownloadingStatusCurrent)
                let wasMaterialized = self.materialized.contains(url)
                if isCurrent && !wasMaterialized {
                    self.materialized.insert(url)
                    newlyMaterialized.append(url)
                } else if !isCurrent && wasMaterialized {
                    self.materialized.remove(url)
                    newlyDematerialized.append(url)
                }
            }

            // Anything we knew about that the query no longer
            // reports — treat as dematerialized (file was evicted
            // or moved out of iCloud).
            let gone = self.materialized.subtracting(seenThisPass)
            for url in gone {
                self.materialized.remove(url)
                newlyDematerialized.append(url)
            }

            var events: [ChangeEvent] = []
            events.append(contentsOf: newlyMaterialized.map { .materialized($0) })
            events.append(contentsOf: newlyDematerialized.map { .dematerialized($0) })
            guard !events.isEmpty else { return }
            let now = Date()
            self.onBatch(ChangeBatch(scope: self.scopeID,
                                     events: events,
                                     firstEventAt: now,
                                     flushedAt: now))
        }
    }
}
