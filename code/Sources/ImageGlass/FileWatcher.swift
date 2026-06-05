import Foundation
import ImageGlassCore

/// Watches a directory for any change (write/delete/rename within) and
/// invokes the callback on a debounce. Uses kqueue via DispatchSource.
final class FileWatcher {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "ImageGlass.FileWatcher")
    private var pendingWorkItem: DispatchWorkItem?
    /// docs/performance.mdx §5.3 — one `FileWatcher.EventBatch` trace
    /// covers one full debounce window. We keep the trace alive across
    /// repeated kqueue events so its `count=` reflects how many raw
    /// events the user-visible batch coalesced.
    private var pendingTrace: PerformanceTrace?
    private var pendingEventCount: Int = 0

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            ErrorLog.log("open(O_EVTONLY) failed for \(url.path) errno=\(errno)",
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
            // docs/performance.mdx §5.3 — `FileWatcher.EventBatch` covers
            // one debounce window. We start the trace on the first event
            // in the window and reuse it for subsequent events so the
            // `count=` payload reflects how many raw events the
            // user-visible batch coalesced.
            if self.pendingTrace == nil {
                self.pendingTrace = PerformanceLog.shared.start(
                    "FileWatcher.EventBatch",
                    extra: [("path", self.url.path)]
                )
            }
            self.pendingEventCount += 1
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let trace = self.pendingTrace
                let count = self.pendingEventCount
                self.pendingTrace = nil
                self.pendingEventCount = 0
                self.onChange()
                trace?.finish(extra: [("count", String(count))])
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
