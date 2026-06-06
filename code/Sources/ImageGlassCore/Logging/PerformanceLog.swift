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
///   * File appends are dispatched through a shared `LogSink`, which
///     formats on the calling thread and writes on a serial utility-QoS
///     background queue. The main thread never blocks on disk I/O.
///   * The writer never throws. Failures are emitted to stderr by the
///     sink and the trace is dropped.
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

    /// Per-action sampling rate. Value N means "emit one in every N
    /// start/finish pairs to disk; drop the rest." A missing entry or
    /// a value of 1 means "emit every pair" (the default and the
    /// pre-existing behaviour). See `setSampling(action:oneInN:)`.
    private var samplingOneInN: [String: Int] = [:]

    /// Per-action counter of pairs dropped under sampling since the
    /// last summary line was emitted. Flushed by an internal threshold
    /// or by `flush()`.
    private var droppedSinceSummary: [String: Int] = [:]

    /// Drop threshold at which we emit one `phase=sampled_summary` line
    /// per action so the analyzer can see the true call rate even when
    /// most pairs are sampled out.
    private let droppedSummaryThreshold: Int = 1024

    /// Cached fixed-width `YYYY-MM-DDTHH:MM:SS` prefix for the wall-clock
    /// second `cachedPrefixSecond` (reference-date integer seconds, UTC).
    /// Reset when a new second rolls over. Guarded by `lock`.
    private var cachedPrefixSecond: Int64 = .min
    private var cachedPrefixBytes: [UInt8] = []

    private let lock = NSLock()
    private let signposter: OSSignposter
    private let sink: LogSink

    public init(overrideLogFile: URL? = nil) {
        self.overrideLogFile = overrideLogFile
        self.signposter = OSSignposter(
            subsystem: "org.imageglass.mac",
            category: "performance"
        )
        // Tests pass `overrideLogFile:` and read the file immediately;
        // honour that contract with synchronous writes on the test path.
        // The production singleton (`shared`) gets the async fast path.
        let isTest = overrideLogFile != nil
        let captured = overrideLogFile
        self.sink = LogSink(
            label: "org.imageglass.mac.performancelog",
            url: { captured ?? AppPaths.macPerformanceLogFile },
            synchronous: isTest
        )
    }

    /// Resolve the path the writer will append to.
    public var logFileURL: URL {
        overrideLogFile ?? AppPaths.macPerformanceLogFile
    }

    /// Block until queued writes have flushed. Production code calls
    /// this at shutdown so an in-flight `phase=finish` line lands
    /// before the process exits.
    public func flush() {
        flushSampledSummaries()
        sink.flush()
    }

    // MARK: - Sampling API

    /// Throttle the named action so only one in every `oneInN` start/finish
    /// pairs lands on disk. The remaining pairs are dropped entirely
    /// (no format, no I/O). A periodic `phase=sampled_summary` line is
    /// emitted so the analyzer still sees the true call rate.
    ///
    /// `oneInN <= 1` clears any sampling for that action.
    /// Defaults to no sampling for every action — behaviour is identical
    /// to the pre-sampling logger until callers opt in.
    public func setSampling(action: String, oneInN: Int) {
        lock.lock()
        if oneInN <= 1 {
            samplingOneInN.removeValue(forKey: action)
        } else {
            samplingOneInN[action] = oneInN
        }
        lock.unlock()
    }

    public func clearSampling(action: String) {
        lock.lock()
        samplingOneInN.removeValue(forKey: action)
        lock.unlock()
    }

    public func clearAllSampling() {
        lock.lock()
        samplingOneInN.removeAll(keepingCapacity: true)
        lock.unlock()
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
        // Reserve the instance number for this action under the lock so
        // two threads racing on the same action get distinct, monotonic
        // instances. The sampling decision is made inside the same
        // critical section so the start/finish pair stays atomic.
        lock.lock()
        let count = (instanceCounters[action] ?? 0) + 1
        instanceCounters[action] = count
        let sampled = decideSampledLocked(action: action, instance: count)
        lock.unlock()

        let started = DispatchTime.now()

        if !sampled {
            // Dropped pair: no I/O, no formatting, no signposter. The
            // trace handle still returns so the caller's `finish()` is a
            // no-op of the same shape — keeps call sites simple.
            recordDroppedStart(action: action)
            return PerformanceTrace.skipped(
                action: action,
                instance: count,
                owner: self,
                startedAt: started
            )
        }

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

        // Write the `phase=start` line. Built-in pairs never need
        // quoting; only the user's `extra` runs through the escape path.
        let line = renderStart(
            action: action,
            instance: count,
            corr: corr,
            extra: extra,
            at: startedWall
        )
        sink.write(Data(line.utf8))

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
        let sampled = decideSampledLocked(action: action, instance: count)
        lock.unlock()
        if !sampled {
            recordDroppedStart(action: action)
            return
        }

        let corr = Self.newCorrelationId()
        let line = renderSingle(
            phase: "event",
            action: action,
            instance: count,
            corr: corr,
            extra: extra,
            at: Date()
        )
        sink.write(Data(line.utf8))

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

        let line = renderFinish(
            action: action,
            instance: instance,
            corr: corr,
            elapsedMs: elapsedMs,
            reason: reason,
            extra: extra,
            at: Date()
        )
        sink.write(Data(line.utf8))

        if mirrorToSignposter, let signpostState {
            let name = Self.staticName(for: action)
            signposter.endInterval(name, signpostState)
        }
        _ = signpostID // silence unused when signposter mirror is off
    }

    // MARK: - Sampling internals

    /// Decide whether this `(action, instance)` pair lands on disk. The
    /// caller holds `lock`. We use modulo on the instance counter so
    /// the decision is deterministic and the start/finish phases agree
    /// (the instance number is the same on both sides).
    private func decideSampledLocked(action: String, instance: Int) -> Bool {
        guard let n = samplingOneInN[action], n > 1 else { return true }
        // instance 1, 1+n, 1+2n, ... land on disk. instance 1 always
        // lands so the first occurrence of every action is captured.
        return ((instance - 1) % n) == 0
    }

    /// Record a dropped start under sampling. May trigger one summary
    /// line if we've crossed the threshold for this action.
    private func recordDroppedStart(action: String) {
        lock.lock()
        let dropped = (droppedSinceSummary[action] ?? 0) + 1
        droppedSinceSummary[action] = dropped
        let shouldEmit = dropped >= droppedSummaryThreshold
        if shouldEmit { droppedSinceSummary[action] = 0 }
        lock.unlock()
        if shouldEmit {
            emitSampledSummary(action: action, dropped: dropped)
        }
    }

    /// Emit any pending sampled-summary lines so the analyzer has the
    /// final tally before the process exits. Called from `flush()`.
    private func flushSampledSummaries() {
        lock.lock()
        let snapshot = droppedSinceSummary.filter { $0.value > 0 }
        droppedSinceSummary.removeAll(keepingCapacity: true)
        lock.unlock()
        for (action, dropped) in snapshot {
            emitSampledSummary(action: action, dropped: dropped)
        }
    }

    private func emitSampledSummary(action: String, dropped: Int) {
        guard enabled else { return }
        let now = Date()
        var line = String()
        line.reserveCapacity(96)
        appendTimestamp(into: &line, at: now)
        line += " phase=sampled_summary action="
        appendEscapedIfNeeded(value: action, into: &line)
        line += " dropped="
        line += String(dropped)
        line += "\n"
        sink.write(Data(line.utf8))
    }

    // MARK: - Formatting (hot path)

    /// Build a `phase=start` line. The four built-in pairs (phase,
    /// action, instance, corr) never need quoting. Only the user's
    /// `extra` runs through the escape branch.
    private func renderStart(
        action: String,
        instance: Int,
        corr: String,
        extra: [(String, String)],
        at when: Date
    ) -> String {
        var line = String()
        line.reserveCapacity(160)
        appendTimestamp(into: &line, at: when)
        line += " phase=start action="
        appendEscapedIfNeeded(value: action, into: &line)
        line += " instance="
        line += String(instance)
        line += " corr="
        line += corr
        appendExtras(extra, into: &line)
        line += "\n"
        return line
    }

    private func renderFinish(
        action: String,
        instance: Int,
        corr: String,
        elapsedMs: Int,
        reason: String?,
        extra: [(String, String)],
        at when: Date
    ) -> String {
        var line = String()
        line.reserveCapacity(176)
        appendTimestamp(into: &line, at: when)
        line += " phase=finish action="
        appendEscapedIfNeeded(value: action, into: &line)
        line += " instance="
        line += String(instance)
        line += " corr="
        line += corr
        line += " elapsed_ms="
        line += String(elapsedMs)
        if let reason {
            line += " reason="
            appendEscapedIfNeeded(value: reason, into: &line)
        }
        appendExtras(extra, into: &line)
        line += "\n"
        return line
    }

    private func renderSingle(
        phase: String,
        action: String,
        instance: Int,
        corr: String,
        extra: [(String, String)],
        at when: Date
    ) -> String {
        var line = String()
        line.reserveCapacity(160)
        appendTimestamp(into: &line, at: when)
        line += " phase="
        line += phase
        line += " action="
        appendEscapedIfNeeded(value: action, into: &line)
        line += " instance="
        line += String(instance)
        line += " corr="
        line += corr
        appendExtras(extra, into: &line)
        line += "\n"
        return line
    }

    private func appendExtras(
        _ pairs: [(String, String)],
        into line: inout String
    ) {
        for (k, v) in pairs {
            line += " "
            line += k
            line += "="
            appendEscapedIfNeeded(value: v, into: &line)
        }
    }

    /// Append `value` to `line`, wrapping in quotes only if it contains
    /// whitespace, `=`, or a quote/newline. Common identifier values
    /// (dotted action names, hex correlation ids, integers) take the
    /// fast path with zero scanning beyond a single pass over the
    /// characters of `value`.
    private func appendEscapedIfNeeded(value: String, into line: inout String) {
        var needsQuoting = false
        for u in value.utf8 {
            if u == 0x20 /* space */ || u == 0x3D /* = */
                || u == 0x09 /* tab */ || u == 0x0A /* \n */
                || u == 0x22 /* " */ {
                needsQuoting = true
                break
            }
        }
        if !needsQuoting {
            line += value
            return
        }
        line += "\""
        // Slow branch: escape embedded quotes.
        if value.contains("\"") {
            line += value.replacingOccurrences(of: "\"", with: "\\\"")
        } else {
            line += value
        }
        line += "\""
    }

    /// Append `YYYY-MM-DDTHH:MM:SS.mmmZ ` to `line`. The seconds
    /// component is cached per integer-second of reference time; only
    /// the milliseconds suffix is rebuilt per call. ~30 ns per emission
    /// in the cache-hit case vs ~1-2 us for `ISO8601DateFormatter`.
    private func appendTimestamp(into line: inout String, at when: Date) {
        let interval = when.timeIntervalSinceReferenceDate
        let wholeSeconds = Int64(interval.rounded(.down))
        let fractional = interval - Double(wholeSeconds)
        var millis = Int(fractional * 1000.0)
        if millis < 0 { millis = 0 }
        if millis > 999 { millis = 999 }

        lock.lock()
        if wholeSeconds != cachedPrefixSecond {
            cachedPrefixBytes = Self.formatSecondPrefixUTC(
                refSeconds: wholeSeconds
            )
            cachedPrefixSecond = wholeSeconds
        }
        // Append the cached "ts=YYYY-MM-DDTHH:MM:SS" bytes verbatim.
        let prefix = cachedPrefixBytes
        lock.unlock()

        // Manually convert the cached ASCII bytes back to String. The
        // bytes are guaranteed ASCII so this is a cheap UTF-8 decode.
        line += String(decoding: prefix, as: UTF8.self)
        line += "."
        // Pad to 3 digits.
        if millis < 10 {
            line += "00"
        } else if millis < 100 {
            line += "0"
        }
        line += String(millis)
        line += "Z"
    }

    /// Build the ASCII bytes for `ts=YYYY-MM-DDTHH:MM:SS` (no millis,
    /// no `Z`) for the given seconds-since-reference-date in UTC. Uses
    /// the proleptic Gregorian calendar via the same `civil_from_days`
    /// arithmetic Howard Hinnant published — branch-free and faster
    /// than touching `Calendar` or `DateFormatter`.
    private static func formatSecondPrefixUTC(refSeconds: Int64) -> [UInt8] {
        // 978307200 = seconds from Unix epoch (1970) to reference date
        // (2001-01-01 00:00:00 UTC).
        let unixSeconds = refSeconds + 978_307_200
        let secondsPerDay: Int64 = 86_400
        var days = unixSeconds / secondsPerDay
        var sod = unixSeconds - days * secondsPerDay
        if sod < 0 { sod += secondsPerDay; days -= 1 }

        let hour = Int(sod / 3600)
        let minute = Int((sod % 3600) / 60)
        let second = Int(sod % 60)

        // Hinnant civil_from_days (Unix-epoch day count → Y/M/D).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = Int(z - era * 146_097) // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 // [0, 399]
        let yInt = Int(yoe) + Int(era) * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100) // [0, 365]
        let mp = (5 * doy + 2) / 153 // [0, 11]
        let day = doy - (153 * mp + 2) / 5 + 1 // [1, 31]
        let month = mp < 10 ? mp + 3 : mp - 9 // [1, 12]
        let year = yInt + (month <= 2 ? 1 : 0)

        var out = [UInt8]()
        out.reserveCapacity(22)
        // "ts=" + year(4) + "-" + month(2) + "-" + day(2) + "T"
        // + hour(2) + ":" + min(2) + ":" + sec(2) = 22 bytes.
        out.append(0x74) // 't'
        out.append(0x73) // 's'
        out.append(0x3D) // '='
        appendASCII4(&out, year)
        out.append(0x2D) // '-'
        appendASCII2(&out, month)
        out.append(0x2D) // '-'
        appendASCII2(&out, day)
        out.append(0x54) // 'T'
        appendASCII2(&out, hour)
        out.append(0x3A) // ':'
        appendASCII2(&out, minute)
        out.append(0x3A) // ':'
        appendASCII2(&out, second)
        return out
    }

    @inline(__always)
    private static func appendASCII4(_ out: inout [UInt8], _ value: Int) {
        let v = value < 0 ? 0 : value
        out.append(UInt8(0x30 + (v / 1000) % 10))
        out.append(UInt8(0x30 + (v / 100) % 10))
        out.append(UInt8(0x30 + (v / 10) % 10))
        out.append(UInt8(0x30 + v % 10))
    }

    @inline(__always)
    private static func appendASCII2(_ out: inout [UInt8], _ value: Int) {
        let v = value < 0 ? 0 : value
        out.append(UInt8(0x30 + (v / 10) % 10))
        out.append(UInt8(0x30 + v % 10))
    }

    /// 8 lowercase hex chars from 32 random bits. Cheaper than the
    /// previous `[UInt8]` + `String(format:)` + `joined()` pipeline:
    /// one `SystemRandomNumberGenerator.next()` call, one tight loop.
    public static func newCorrelationId() -> String {
        var rng = SystemRandomNumberGenerator()
        var v = rng.next() as UInt32
        // Build right-to-left into a fixed 8-byte buffer.
        let hex: [UInt8] = [
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
            0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66,
        ]
        var buf = [UInt8](repeating: 0, count: 8)
        var i = 7
        while i >= 0 {
            buf[i] = hex[Int(v & 0x0F)]
            v >>= 4
            i -= 1
        }
        return String(decoding: buf, as: UTF8.self)
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
    /// True for traces that were dropped by the sampling rate. `finish`
    /// on a skipped trace is a no-op so call sites stay uniform.
    private let isSkipped: Bool

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
        self.isSkipped = false
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
        self.isSkipped = false
        self.closed = true
    }

    private init(
        skippedAction action: String,
        instance: Int,
        owner: PerformanceLog,
        startedAt: DispatchTime
    ) {
        self.owner = owner
        self.action = action
        self.instance = instance
        self.corr = "00000000"
        self.startedAt = startedAt
        self.startedWall = Date()
        self.signpostID = .invalid
        self.signpostState = nil
        self.isDisabled = false
        self.isSkipped = true
        // `closed = true` so `finish` / deinit are pure no-ops.
        self.closed = true
    }

    fileprivate static func disabled(action: String, owner: PerformanceLog) -> PerformanceTrace {
        PerformanceTrace(disabledAction: action, owner: owner)
    }

    fileprivate static func skipped(
        action: String,
        instance: Int,
        owner: PerformanceLog,
        startedAt: DispatchTime
    ) -> PerformanceTrace {
        PerformanceTrace(
            skippedAction: action,
            instance: instance,
            owner: owner,
            startedAt: startedAt
        )
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
        guard !isDisabled, !isSkipped, let owner else { return }
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
        if !closed, !isDisabled, !isSkipped {
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
