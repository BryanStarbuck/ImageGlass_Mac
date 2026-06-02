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
            let work = DispatchWorkItem { self.onChange() }
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
