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
// The writer is serialized through a private utility-QoS dispatch queue so
// concurrent callers from multiple actors do not interleave bytes on disk.

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

        Self.queue.async {
            Self.append(entry)
        }
    }

    /// Absolute path to the log file. Exposed for tests and tooling.
    /// Resolves to `AppPaths.macLogFile`, the same file MCPAuditLogger writes
    /// to, so all observability for ImageGlass_Mac lives in one place.
    public static var logURL: URL {
        return AppPaths.macLogFile
    }

    // MARK: - Internals

    private static let queue = DispatchQueue(
        label: "org.imageglass.mac.errorlog",
        qos: .utility
    )

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func append(_ entry: String) {
        let url = AppPaths.macLogFile
        let dir = url.deletingLastPathComponent()

        // Ensure the parent directory exists. Failures here cannot themselves
        // call ErrorLog (we'd recurse), so fall back to stderr.
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(
                Data("ErrorLog: cannot create \(dir.path): \(error)\n".utf8)
            )
            return
        }

        guard let data = entry.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(
                Data("ErrorLog: cannot append to \(url.path): \(error)\n".utf8)
            )
        }
    }
}
