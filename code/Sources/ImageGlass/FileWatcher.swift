import Foundation
import ImageGlassCore

/// Watches a directory for any change (write/delete/rename within) and
/// invokes the callback on a debounce. Uses kqueue via DispatchSource.
final class FileWatcher {
    private let url: URL
    private let pathString: String
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "ImageGlass.FileWatcher")
    private var pendingWorkItem: DispatchWorkItem?
    /// docs/performance.mdx §5.3 — `FileWatcher.EventBatch` measures the
    /// user-visible coalesced-batch work only. The trace is started inside
    /// the debounce work item, NOT in setEventHandler, so the 250 ms
    /// coalesce window is not counted as work. `pendingEventCount` is
    /// preserved across debounce so the `count=` payload still reflects
    /// every raw kqueue event in the window.
    private var pendingEventCount: Int = 0

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.pathString = url.path
        self.onChange = onChange
    }

    func start() {
        let fd = open(pathString, O_EVTONLY)
        guard fd >= 0 else {
            ErrorLog.log("open(O_EVTONLY) failed for \(pathString) errno=\(errno)",
                         class: "FileWatcher")
            return
        }
        fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.pendingWorkItem?.cancel()
            self.pendingEventCount += 1
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let count = self.pendingEventCount
                self.pendingEventCount = 0
                let trace = PerformanceLog.shared.start(
                    "FileWatcher.EventBatch",
                    extra: [("path", self.pathString)]
                )
                self.onChange()
                trace.finish(extra: [("count", String(count))])
            }
            self.pendingWorkItem = work
            // Spec §6.6: debounce 250 ms so bulk filesystem ops (e.g. cp -R)
            // collapse to a single re-evaluation.
            self.queue.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        src.resume()
        self.source = src
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit {
        cancel()
    }
}
