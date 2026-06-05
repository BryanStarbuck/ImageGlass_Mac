import Foundation
import os

/// Append-only writer for the performance log specified in
/// `docs/performance.mdx`. Output sink:
/// `~/Library/Application Support/ImageGlass_Mac/performance.log`.
///
/// Every measured action emits exactly two lines: one when the action
/// starts and one when it finishes. Both lines carry the same
/// `action=` name, the same `instance=<n>` counter (so the analyzer can
/// pair the 17th start with the 17th finish for a given action even
/// when other actions interleave between them), and the same
/// `corr=<8hex>` correlation id.
///
/// Line grammar (one entry per line):
///
/// ```
/// ts=<ISO8601-ms> phase=start  action=<dotted.name> instance=<n> corr=<8hex> [k=v ...]
/// ts=<ISO8601-ms> phase=finish action=<dotted.name> instance=<n> corr=<8hex> elapsed_ms=<n> [k=v ...]
/// ```
///
/// All entries are mirrored to an `OSSignposter` so they also show up in
/// Xcode's Instruments timeline. The file-based log is the canonical
/// source for offline analysis (the user's stated goal: "later have AI
/// analyze that log file").
///
/// Concurrency model:
///   * Per-action instance counters live in a single dictionary guarded
///     by `lock`. Increments are serialized so the counter monotonically
///     ascends without races.
///   * File appends are also serialized through `lock` so concurrent
///     calls from multiple actors do not interleave bytes.
///   * The writer never throws. Failures fall through to `ErrorLog` and
///     the trace is dropped.
public final class PerformanceLog: @unchecked Sendable {

    public static let shared = PerformanceLog()

    /// When false the file writer becomes a no-op and `start` returns a
    /// disabled `PerformanceTrace` that does nothing on `finish`. The
    /// `OSSignposter` mirror is also suppressed. Defaults to `true`.
    /// Tests flip this off so they don't leak entries into the shared
    /// log on disk.
    public var enabled: Bool = true

    /// Override the on-disk path. Used by tests so they can point at a
    /// temp file. Honored only on the next `start`; existing traces
    /// finish to whatever path they were started under.
    public var overrideLogFile: URL?

    /// Get/set whether each entry is mirrored to `OSSignposter`. The
    /// signposter is shared process-wide so Instruments can find every
    /// action under one `Subsystem`/`Category`.
    public var mirrorToSignposter: Bool = true

    /// Monotonic per-action counter. Key is the action name; value is
    /// the count of `start()` calls so far. The "instance number" of a
    /// trace is its count at the moment of `start`.
    private var instanceCounters: [String: Int] = [:]

    private let lock = NSLock()
    private let dateFormatter: ISO8601DateFormatter
    private let signposter: OSSignposter

    public init(overrideLogFile: URL? = nil) {
        self.overrideLogFile = overrideLogFile
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        self.dateFormatter = f
        self.signposter = OSSignposter(
            subsystem: "org.imageglass.mac",
            category: "performance"
        )
    }

    /// Resolve the path the writer will append to.
    public var logFileURL: URL {
        overrideLogFile ?? AppPaths.macPerformanceLogFile
    }

    // MARK: - Public API

    /// Begin a measured action. Returns a handle the caller must
    /// `finish()` (or `cancel()`) on. If the caller drops the handle
    /// without calling either, the trace auto-finishes via `deinit`
    /// with `reason=auto_finish` so we still see how long the work took
    /// in the log.
    ///
    /// - Parameters:
    ///   - action: Dotted action name. Use the taxonomy from
    ///             `docs/performance.mdx` §5. Free-form is allowed but
    ///             prefer registering new names in the spec first.
    ///   - extra:  Optional context pairs written on the `start` line.
    ///             Common keys: `path`, `count`, `bytes`, `source`,
    ///             `mode`. Keep the value short — these go on every line.
    @discardableResult
    public func start(
        _ action: String,
        extra: [(String, String)] = []
    ) -> PerformanceTrace {
        guard enabled else {
            return PerformanceTrace.disabled(action: action, owner: self)
        }
        // Reserve the instance number for this action and the start
        // timestamp under the same lock so two threads racing on the
        // same action get distinct, monotonically ordered instances.
        lock.lock()
        let count = (instanceCounters[action] ?? 0) + 1
        instanceCounters[action] = count
        lock.unlock()

        let started = DispatchTime.now()
        let corr = Self.newCorrelationId()
        let startedWall = Date()

        // OSSignposter interval — the OS marks an entry that Instruments
        // pairs with the end token automatically.
        let signpostID = signposter.makeSignpostID()
        let signpostState: OSSignpostIntervalState?
        if mirrorToSignposter {
            let name = Self.staticName(for: action)
            signpostState = signposter.beginInterval(
                name, id: signpostID, "\(corr) #\(count)"
            )
        } else {
            signpostState = nil
        }

        // Write the `phase=start` line.
        var pairs: [(String, String)] = [
            ("phase", "start"),
            ("action", action),
            ("instance", String(count)),
            ("corr", corr),
        ]
        pairs.append(contentsOf: extra)
        append(line: render(pairs: pairs, at: startedWall))

        return PerformanceTrace(
            owner: self,
            action: action,
            instance: count,
            corr: corr,
            startedAt: started,
            startedWall: startedWall,
            signpostID: signpostID,
            signpostState: signpostState
        )
    }

    /// Single-shot event with no duration. Useful for "first frame
    /// painted" or "first byte read" style markers. Emits one line:
    /// `phase=event action=<...> instance=<n> corr=<8hex> [k=v ...]`.
    public func event(
        _ action: String,
        extra: [(String, String)] = []
    ) {
        guard enabled else { return }
        lock.lock()
        let count = (instanceCounters[action] ?? 0) + 1
        instanceCounters[action] = count
        lock.unlock()

        let corr = Self.newCorrelationId()
        var pairs: [(String, String)] = [
            ("phase", "event"),
            ("action", action),
            ("instance", String(count)),
            ("corr", corr),
        ]
        pairs.append(contentsOf: extra)
        append(line: render(pairs: pairs, at: Date()))

        if mirrorToSignposter {
            let name = Self.staticName(for: action)
            signposter.emitEvent(name, "\(corr) #\(count)")
        }
    }

    // MARK: - Trace completion (called by `PerformanceTrace`)

    /// Write the matching `phase=finish` line. Called by
    /// `PerformanceTrace.finish` and by `deinit` when the caller forgot.
    fileprivate func finish(
        action: String,
        instance: Int,
        corr: String,
        startedAt: DispatchTime,
        signpostID: OSSignpostID,
        signpostState: OSSignpostIntervalState?,
        reason: String?,
        extra: [(String, String)]
    ) {
        let endedAt = DispatchTime.now()
        let elapsedNanos = endedAt.uptimeNanoseconds &- startedAt.uptimeNanoseconds
        let elapsedMs = Int(elapsedNanos / 1_000_000)

        var pairs: [(String, String)] = [
            ("phase", "finish"),
            ("action", action),
            ("instance", String(instance)),
            ("corr", corr),
            ("elapsed_ms", String(elapsedMs)),
        ]
        if let reason { pairs.append(("reason", reason)) }
        pairs.append(contentsOf: extra)
        append(line: render(pairs: pairs, at: Date()))

        if mirrorToSignposter, let signpostState {
            let name = Self.staticName(for: action)
            signposter.endInterval(name, signpostState)
        }
        _ = signpostID // silence unused when signposter mirror is off
    }

    // MARK: - File I/O

    private func append(line: String) {
        guard let data = line.data(using: .utf8) else {
            ErrorLog.log("failed to encode performance line", class: "PerformanceLog")
            return
        }
        lock.lock()
        defer { lock.unlock() }
        let url = logFileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            ErrorLog.log(
                "could not create performance log parent dir \(url.deletingLastPathComponent().path)",
                error: error, class: "PerformanceLog"
            )
            return
        }
        if !fm.fileExists(atPath: url.path) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                ErrorLog.log("failed to create performance log at \(url.path)",
                             error: error, class: "PerformanceLog")
            }
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            ErrorLog.log("failed to append to performance log at \(url.path)",
                         error: error, class: "PerformanceLog")
        }
    }

    // MARK: - Formatting

    private func render(pairs: [(String, String)], at when: Date) -> String {
        var line = "ts=\(dateFormatter.string(from: when))"
        for (k, v) in pairs {
            line += " "
            line += k
            line += "="
            line += format(value: v)
        }
        line += "\n"
        return line
    }

    private func format(value: String) -> String {
        if value.contains(" ") || value.contains("=") || value.contains("\t")
            || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }

    public static func newCorrelationId() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `OSSignposter` requires a `StaticString` for the action name.
    /// We map every dotted action name to a compact static label so
    /// Instruments can group entries by category. The label collapses
    /// related actions onto one timeline lane.
    private static func staticName(for action: String) -> StaticString {
        if action.hasPrefix("FileTree.") { return "FileTree" }
        if action.hasPrefix("DirectoryWalk.") { return "DirectoryWalk" }
        if action.hasPrefix("Refilter.") { return "Refilter" }
        if action.hasPrefix("Image.") { return "Image" }
        if action.hasPrefix("Thumbnail.") { return "Thumbnail" }
        if action.hasPrefix("Settings.") { return "Settings" }
        if action.hasPrefix("Layout.") { return "Layout" }
        if action.hasPrefix("LocalStorage.") { return "LocalStorage" }
        if action.hasPrefix("MCP.") { return "MCP" }
        if action.hasPrefix("Scope.") { return "Scope" }
        if action.hasPrefix("Crop.") { return "Crop" }
        if action.hasPrefix("Video.") { return "Video" }
        if action.hasPrefix("SVG.") { return "SVG" }
        if action.hasPrefix("Theme.") { return "Theme" }
        if action.hasPrefix("Releases.") { return "Releases" }
        if action.hasPrefix("ExternalTool.") { return "ExternalTool" }
        if action.hasPrefix("AppLaunch.") { return "AppLaunch" }
        if action.hasPrefix("Window.") { return "Window" }
        if action.hasPrefix("Panel.") { return "Panel" }
        if action.hasPrefix("Format.") { return "Format" }
        if action.hasPrefix("Slideshow.") { return "Slideshow" }
        if action.hasPrefix("Tree.") { return "Tree" }
        return "Other"
    }
}

/// Handle returned by `PerformanceLog.start`. The owning trace is open
/// until `finish` or `cancel` is called, or the handle is deallocated
/// (in which case the trace auto-finishes with `reason=auto_finish`).
public final class PerformanceTrace: @unchecked Sendable {

    fileprivate weak var owner: PerformanceLog?
    public let action: String
    public let instance: Int
    public let corr: String
    fileprivate let startedAt: DispatchTime
    fileprivate let startedWall: Date
    fileprivate let signpostID: OSSignpostID
    fileprivate let signpostState: OSSignpostIntervalState?

    private let lock = NSLock()
    private var closed: Bool = false
    private let isDisabled: Bool

    fileprivate init(
        owner: PerformanceLog,
        action: String,
        instance: Int,
        corr: String,
        startedAt: DispatchTime,
        startedWall: Date,
        signpostID: OSSignpostID,
        signpostState: OSSignpostIntervalState?
    ) {
        self.owner = owner
        self.action = action
        self.instance = instance
        self.corr = corr
        self.startedAt = startedAt
        self.startedWall = startedWall
        self.signpostID = signpostID
        self.signpostState = signpostState
        self.isDisabled = false
    }

    private init(disabledAction action: String, owner: PerformanceLog) {
        self.owner = owner
        self.action = action
        self.instance = 0
        self.corr = "00000000"
        self.startedAt = DispatchTime.now()
        self.startedWall = Date()
        self.signpostID = .invalid
        self.signpostState = nil
        self.isDisabled = true
        self.closed = true
    }

    fileprivate static func disabled(action: String, owner: PerformanceLog) -> PerformanceTrace {
        PerformanceTrace(disabledAction: action, owner: owner)
    }

    /// Write the matching `phase=finish` line. Subsequent calls are
    /// no-ops, so it is safe to call from both a happy-path `defer` and
    /// a fall-through error branch.
    public func finish(extra: [(String, String)] = []) {
        complete(reason: nil, extra: extra)
    }

    /// Same as `finish` but tags the line with `reason=<reason>` so the
    /// analyzer can distinguish "completed normally", "completed with
    /// an error", "cancelled because a newer action superseded this
    /// one", etc.
    public func finish(reason: String, extra: [(String, String)] = []) {
        complete(reason: reason, extra: extra)
    }

    /// Treat the trace as cancelled. Writes the finish line with
    /// `reason=cancelled` and the elapsed time so we can still see how
    /// long the abandoned work took.
    public func cancel(extra: [(String, String)] = []) {
        complete(reason: "cancelled", extra: extra)
    }

    private func complete(reason: String?, extra: [(String, String)]) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        guard !isDisabled, let owner else { return }
        owner.finish(
            action: action,
            instance: instance,
            corr: corr,
            startedAt: startedAt,
            signpostID: signpostID,
            signpostState: signpostState,
            reason: reason,
            extra: extra
        )
    }

    deinit {
        // Caller dropped the trace without calling `finish`. Auto-close
        // so we still see the duration.
        if !closed, !isDisabled {
            complete(reason: "auto_finish", extra: [])
        }
    }
}

// MARK: - Sugar

extension PerformanceLog {

    /// Run `body` and measure its duration as the named action. The
    /// trace is finished as soon as `body` returns, regardless of
    /// whether it threw.
    @discardableResult
    public func measure<T>(
        _ action: String,
        extra: [(String, String)] = [],
        _ body: () throws -> T
    ) rethrows -> T {
        let trace = start(action, extra: extra)
        defer { trace.finish() }
        return try body()
    }

    /// Async variant. Suspended time also counts toward `elapsed_ms`,
    /// which is intentional: from the user's perspective the action is
    /// "in progress" the whole time.
    @discardableResult
    public func measureAsync<T>(
        _ action: String,
        extra: [(String, String)] = [],
        _ body: () async throws -> T
    ) async rethrows -> T {
        let trace = start(action, extra: extra)
        defer { trace.finish() }
        return try await body()
    }
}
