// ErrorLog.swift
//
// Shared error-logging facility for ImageGlass_Mac.
//
// All callers in ImageGlass, igcmd, ImageGlassMCPServer, and ImageGlassCore
// should funnel error / unexpected-condition reports through `ErrorLog.log`
// instead of writing ad-hoc `print` statements or silently swallowing errors.
//
// Output sink (shared with MCPAuditLogger):
//   ~/Library/Application Support/ImageGlass_Mac/log.log
//
// Error entries are appended on their own line and contain:
//   [ISO-8601 timestamp] [source file path:line] [function] [class] message error=<err>
//
// MCPAuditLogger writes structured `ts=… tool=…` / `ts=… app=…` lines into
// the same file; the two formats are unambiguously distinguishable so grep
// can isolate either stream (`grep '^\['` for errors, `grep '^ts='` for
// audit records).
//
// The writer is serialized through a shared `LogSink` so the caller's
// thread (often the main thread) returns as soon as the line is formatted
// — the actual `write(2)` lands on a background utility queue. The sink
// also self-rotates the file at 10 MB.

import Foundation

public enum ErrorLog {

    // MARK: - Public API

    /// Append one error entry to the shared `log.log` file.
    ///
    /// - Parameters:
    ///   - message:   Human-readable description of what went wrong.
    ///   - error:     The underlying `Error` value, if any. Will be appended as `error=<value>`.
    ///   - className: The Swift type (class / struct / actor / enum) the error
    ///                originated in. Pass `String(describing: Self.self)`
    ///                from instance methods, or the literal type name from
    ///                free functions and `@main` entry points.
    ///   - file:      Captured automatically from `#filePath`.
    ///   - function:  Captured automatically from `#function`.
    ///   - line:      Captured automatically from `#line`.
    public static func log(
        _ message: String,
        error: Error? = nil,
        class className: String? = nil,
        file: String = #filePath,
        function: String = #function,
        line: Int = #line
    ) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let classPart = className.map { " [\($0)]" } ?? ""
        let errorPart = error.map { " error=\(String(reflecting: $0))" } ?? ""
        let entry = "[\(timestamp)] [\(file):\(line)] [\(function)]\(classPart) \(message)\(errorPart)\n"
        if let data = entry.data(using: .utf8) {
            sink.write(data)
        }
    }

    /// Absolute path to the log file. Exposed for tests and tooling.
    /// Resolves to `AppPaths.macLogFile`, the same file MCPAuditLogger writes
    /// to, so all observability for ImageGlass_Mac lives in one place.
    public static var logURL: URL {
        return AppPaths.macLogFile
    }

    /// Block until queued entries have flushed. Production code calls
    /// this at shutdown so a fatal error landing right before exit is
    /// not lost.
    public static func flush() {
        sink.flush()
    }

    // MARK: - Internals

    private static let sink = LogSink(
        label: "org.imageglass.mac.errorlog",
        url: { AppPaths.macLogFile }
    )

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
