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
    /// Self-arming watcher attached to the parent directory when the
    /// target path does not exist yet (ENOENT). Several runtime-state
    /// files (`slideshow.txt`, etc.) are only written on first MCP /
    /// user action, so the GUI legitimately starts a watcher before the
    /// file exists. When the parent dir fires, we retry `open()` and,
    /// on success, tear down the parent watcher and arm the real one.
    private var parentSource: DispatchSourceFileSystemObject?
    private var parentFileDescriptor: Int32 = -1
    /// True once `cancel()` has been called. Prevents the parent-dir
    /// retry path from re-attaching a watcher after the owner cancelled.
    private var cancelled: Bool = false
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
            let err = errno
            // ENOENT is the normal first-run state for runtime-state
            // files the app writes on first action (slideshow.txt,
            // panel_view_mode.txt before any MCP write, etc.). Do not
            // pollute `log.log` with an error line for the expected
            // case; instead arm a parent-directory watcher that will
            // retry `open()` once the file appears. All other errnos
            // (EACCES, EMFILE, ENFILE, …) are real problems and keep
            // their existing error-severity logging.
            if err == ENOENT {
                armParentDirectoryRetry()
                return
            }
            ErrorLog.log("open(O_EVTONLY) failed for \(pathString) errno=\(err)",
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
        queue.sync {
            cancelled = true
            source?.cancel()
            source = nil
            parentSource?.cancel()
            parentSource = nil
        }
    }

    /// Attach a kqueue watcher to the parent directory and, on the next
    /// write/extend/rename event there, retry `open(O_EVTONLY)` on the
    /// real path. Once the file appears the parent watcher is cancelled
    /// and the normal `start()` path is invoked to wire up the
    /// per-file watcher + event handler. The retry is silent — at most
    /// one debug-level signal is produced if the parent directory
    /// itself is missing (which is itself a real error).
    private func armParentDirectoryRetry() {
        let parentPath = url.deletingLastPathComponent().path
        let pfd = open(parentPath, O_EVTONLY)
        guard pfd >= 0 else {
            // Parent dir missing is unusual — log it. Caller can decide
            // whether to create the directory tree before watching.
            ErrorLog.log("open(O_EVTONLY) on parent dir failed for \(parentPath) errno=\(errno) (target=\(pathString))",
                         class: "FileWatcher")
            return
        }
        queue.sync {
            if cancelled {
                close(pfd)
                return
            }
            parentFileDescriptor = pfd
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: pfd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: queue
            )
            src.setEventHandler { [weak self] in
                guard let self else { return }
                // File may now exist. Try to attach the real watcher.
                // Re-test cancellation: cancel() may have been called
                // between event delivery and handler entry.
                if self.cancelled { return }
                // Probe without holding state: a separate open() inside
                // start() will succeed once the file exists.
                if access(self.pathString, F_OK) == 0 {
                    self.parentSource?.cancel()
                    self.parentSource = nil
                    // Re-enter start() outside the parent-source handler
                    // so the new source is owned by `self.source`.
                    self.start()
                }
            }
            src.setCancelHandler { [weak self] in
                guard let self else { return }
                if self.parentFileDescriptor >= 0 {
                    close(self.parentFileDescriptor)
                    self.parentFileDescriptor = -1
                }
            }
            src.resume()
            self.parentSource = src
        }
    }

    deinit {
        cancel()
    }
}
