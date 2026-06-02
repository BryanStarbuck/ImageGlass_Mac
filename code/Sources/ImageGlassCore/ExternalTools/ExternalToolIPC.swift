import Foundation

/// IPC bridge between ImageGlass and integration-mode external tools.
///
/// ## Why a Unix-domain socket?
///
/// The upstream Windows SDK uses anonymous pipes / named pipes — neither of
/// which is a natural fit on macOS. We chose Unix-domain sockets because:
///
///   1. **Mac-native, no daemon.** AF_UNIX sockets are first-class in Darwin
///      and Foundation. They live on the filesystem like any other file, so
///      we can put them under `~/Library/Application Support/ImageGlass/runtime/`
///      and they inherit the app's sandbox / permissions.
///   2. **Multiple subscribers.** Many tools may connect at once (ExifGlass +
///      external editor + cloud sync). A socket fans out trivially. stdin/stdout
///      of one launched subprocess does not.
///   3. **Survives launcher fan-out.** A tool registered as "integration" may
///      be launched once and stay alive across many image changes, or be
///      launched per-image. Either model works because the socket path is
///      passed in env (`IMAGEGLASS_SOCKET_PATH`) so the tool can connect on
///      demand.
///   4. **Simple wire format.** Newline-delimited JSON — exactly what the MCP
///      server already speaks — so the same `MCP.Request`/`Response` mental
///      model carries over.
///
/// ## Wire format
///
/// One JSON message per line, no framing prefix:
///
/// ```json
/// { "type": "IMAGE_LOADED", "path": "/Users/me/Pictures/sunset.jpg" }
/// { "type": "CLOSING" }
/// ```
///
/// `type` matches the upstream `MessageName` field. Tools may write JSON
/// messages back; the server forwards them via `incomingMessageHandler`.
///
/// ## Lifecycle
///
/// `start()` creates the listening socket on a background dispatch source.
/// `stop()` closes the listener and notifies connected tools with `CLOSING`.
/// All connected tools receive every broadcast via `broadcast(...)`.
///
/// Marked `@unchecked Sendable` because Darwin file descriptors + DispatchSource
/// are not Sendable, but we synchronize all mutation through `queue`.
public final class ExternalToolIPC: @unchecked Sendable {

    public static let socketEnvKey = "IMAGEGLASS_SOCKET_PATH"

    private let socketPath: String
    private let queue = DispatchQueue(label: "imageglass.externaltools.ipc")

    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientFDs: Set<Int32> = []
    private var clientSources: [Int32: DispatchSourceRead] = [:]

    /// Called on the IPC queue when a tool sends a JSON message back.
    public var incomingMessageHandler: (@Sendable (_ fromFD: Int32, _ json: [String: Any]) -> Void)?

    public init(socketPath: String? = nil) {
        if let p = socketPath {
            self.socketPath = p
        } else {
            self.socketPath = AppPaths.runtimeDir
                .appendingPathComponent("tools.sock")
                .path
        }
    }

    public var path: String { socketPath }

    // MARK: - Lifecycle

    /// Begin listening. Returns true if the socket is up.
    @discardableResult
    public func start() -> Bool {
        var didStart = false
        queue.sync {
            guard listenFD < 0 else { didStart = true; return }
            do {
                try AppPaths.ensureDirectories()
            } catch {
                ErrorLog.log("AppPaths.ensureDirectories failed",
                             error: error,
                             class: String(describing: Self.self))
                return
            }
            // Clean stale socket file.
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                // Missing file is expected; log other failures.
                let nsErr = error as NSError
                if !(nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError) {
                    ErrorLog.log("removeItem(atPath:) failed for stale socket \(socketPath)",
                                 error: error,
                                 class: String(describing: Self.self))
                }
            }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                ErrorLog.log("socket(AF_UNIX, SOCK_STREAM, 0) failed errno=\(errno)",
                             class: String(describing: Self.self))
                return
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
            guard pathBytes.count <= maxLen else {
                ErrorLog.log("socket path too long (\(pathBytes.count) > \(maxLen)) for \(socketPath)",
                             class: String(describing: Self.self))
                close(fd)
                return
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                p.withMemoryRebound(to: UInt8.self, capacity: maxLen + 1) { dest in
                    for (i, b) in pathBytes.enumerated() { dest[i] = b }
                    dest[pathBytes.count] = 0
                }
            }

            let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindRes == 0 else {
                ErrorLog.log("bind() failed for socket \(socketPath) errno=\(errno)",
                             class: String(describing: Self.self))
                close(fd)
                return
            }
            guard listen(fd, 8) == 0 else {
                ErrorLog.log("listen() failed for socket \(socketPath) errno=\(errno)",
                             class: String(describing: Self.self))
                close(fd)
                return
            }

            self.listenFD = fd
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in
                self?.acceptClient()
            }
            src.resume()
            self.listenSource = src
            didStart = true
        }
        return didStart
    }

    /// Stop the listener and disconnect all clients (with a CLOSING message).
    public func stop() {
        queue.sync {
            // Notify connected tools.
            let bye = (try? JSONSerialization.data(withJSONObject: ["type": "CLOSING"]))
                ?? Data("{\"type\":\"CLOSING\"}".utf8)
            for fd in clientFDs {
                writeLine(bye, to: fd)
            }
            for (_, src) in clientSources { src.cancel() }
            clientSources.removeAll()
            for fd in clientFDs { close(fd) }
            clientFDs.removeAll()

            listenSource?.cancel()
            listenSource = nil
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
            }
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                let nsErr = error as NSError
                if !(nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError) {
                    ErrorLog.log("removeItem(atPath:) failed for socket \(socketPath) on stop",
                                 error: error,
                                 class: String(describing: Self.self))
                }
            }
        }
    }

    deinit {
        // Best-effort cleanup; close any still-open FDs directly without
        // touching the dispatch queue (which may be torn down already).
        for fd in clientFDs { close(fd) }
        if listenFD >= 0 { close(listenFD) }
    }

    // MARK: - Broadcast

    /// Send an `IMAGE_LOADED` event to every connected tool.
    public func broadcastImageLoaded(path: String) {
        broadcast(["type": "IMAGE_LOADED", "path": path])
    }

    public func broadcast(_ message: [String: Any]) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        } catch {
            ErrorLog.log("JSONSerialization.data(withJSONObject:) failed for broadcast",
                         error: error,
                         class: String(describing: Self.self))
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            for fd in self.clientFDs {
                self.writeLine(data, to: fd)
            }
        }
    }

    /// Number of currently connected tools (snapshot — for tests / status UI).
    public var connectedCount: Int {
        queue.sync { clientFDs.count }
    }

    // MARK: - Internals (queue-confined)

    private func acceptClient() {
        var clientAddr = sockaddr()
        var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
        let cfd = accept(listenFD, &clientAddr, &len)
        guard cfd >= 0 else {
            ErrorLog.log("accept() failed on listen FD errno=\(errno)",
                         class: String(describing: Self.self))
            return
        }

        clientFDs.insert(cfd)

        let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.readFromClient(cfd)
        }
        src.setCancelHandler {
            close(cfd)
        }
        src.resume()
        clientSources[cfd] = src
    }

    private func readFromClient(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            read(fd, ptr.baseAddress, ptr.count)
        }
        if n <= 0 {
            // EOF or error — drop client.
            if let src = clientSources.removeValue(forKey: fd) { src.cancel() }
            clientFDs.remove(fd)
            return
        }
        // Split on newlines; emit one event per JSON line.
        var start = 0
        for i in 0..<n {
            if buf[i] == 0x0A {
                if i > start {
                    let line = Data(buf[start..<i])
                    do {
                        if let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            incomingMessageHandler?(fd, obj)
                        } else {
                            ErrorLog.log("client JSON line was not a top-level object on fd \(fd)",
                                         class: String(describing: Self.self))
                        }
                    } catch {
                        ErrorLog.log("JSONSerialization.jsonObject failed for client line on fd \(fd)",
                                     error: error,
                                     class: String(describing: Self.self))
                    }
                }
                start = i + 1
            }
        }
    }

    private func writeLine(_ data: Data, to fd: Int32) {
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var ptr = base
            while remaining > 0 {
                let w = write(fd, ptr, remaining)
                if w <= 0 { break }
                remaining -= w
                ptr = ptr.advanced(by: w)
            }
        }
    }
}
