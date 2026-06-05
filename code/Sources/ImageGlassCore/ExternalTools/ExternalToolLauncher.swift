import Foundation

/// Launches third-party tools registered with ImageGlass.
///
/// Responsibilities:
///   * Expand `<file>` placeholders in the argument template.
///   * Tokenize the argument template into an argv array using a small
///     POSIX-style shell tokenizer (handles single & double quotes and
///     backslash escapes — no `$VAR` expansion, no globbing, no pipes).
///   * Resolve the executable path (`~` expansion).
///   * Spawn the tool via `Process`.
///
/// Pure logic where possible — placeholder substitution and argv assembly
/// are exposed as static methods so tests can verify them without spawning
/// any subprocess.
public final class ExternalToolLauncher {

    /// Token recognized in the argument template.
    public static let filePlaceholder = "<file>"

    public init() {}

    // MARK: - Public API

    /// Build the argv array (without the executable itself) that would be
    /// passed to `Process` for the given tool + current image path.
    /// Exposed as a pure function so tests can verify substitution
    /// independently of any actual spawn.
    public static func buildArguments(template: String, filePath: String?) -> [String] {
        let tokens = tokenize(template)
        return tokens.map { token in
            substitutePlaceholders(in: token, filePath: filePath)
        }
    }

    /// Resolved executable path (tilde-expanded, but not validated).
    public static func resolvedExecutable(for tool: ExternalTool) -> String {
        AppPaths.expandTilde(tool.executablePath)
    }

    /// Launch the tool with the given image path.
    ///
    /// Returns the spawned `Process` (already started). The caller may
    /// ignore the return value for fire-and-forget tools.
    ///
    /// - Parameter integrationEnv: Optional environment dictionary to merge
    ///   into the child process — typically `IMAGEGLASS_SOCKET_PATH` from
    ///   `ExternalToolIPC` so integration-mode tools know where to connect.
    @discardableResult
    public func launch(
        _ tool: ExternalTool,
        filePath: String?,
        integrationEnv: [String: String] = [:]
    ) throws -> Process {
        // §5.6 `ExternalTool.Launch` — measures argv assembly + subprocess
        // spawn. `process.run()` returns once the OS fork/exec succeeds,
        // not when the child has done meaningful work, so this elapsed
        // captures "how long until the child is alive".
        let _trace = PerformanceLog.shared.start(
            "ExternalTool.Launch",
            extra: [
                ("tool", tool.id),
                ("integration", tool.integration ? "1" : "0"),
            ]
        )
        defer { _trace.finish() }

        let exe = ExternalToolLauncher.resolvedExecutable(for: tool)
        guard FileManager.default.fileExists(atPath: exe) else {
            throw ExternalToolError.executableMissing(exe)
        }

        let args = ExternalToolLauncher.buildArguments(
            template: tool.arguments,
            filePath: filePath
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args

        // Inherit current environment and overlay integration values.
        var env = ProcessInfo.processInfo.environment
        if tool.integration {
            for (k, v) in integrationEnv { env[k] = v }
            env["IMAGEGLASS_INTEGRATION"] = "1"
            env["IMAGEGLASS_TOOL_ID"] = tool.id
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            ErrorLog.log("process.run() failed for tool '\(tool.id)' exe=\(exe)",
                         error: error,
                         class: String(describing: Self.self))
            throw ExternalToolError.launchFailed("\(error)")
        }
        return process
    }

    // MARK: - Tokenizer / placeholder substitution

    /// Substitute known placeholders inside a single already-tokenized argv element.
    /// Currently just `<file>`; written this way to make it trivial to add more.
    public static func substitutePlaceholders(in token: String, filePath: String?) -> String {
        guard token.contains(filePlaceholder) else { return token }
        let replacement = filePath ?? ""
        return token.replacingOccurrences(of: filePlaceholder, with: replacement)
    }

    /// Split an argument template into argv tokens with POSIX-style quoting.
    ///
    /// Rules (kept intentionally small):
    ///   * Whitespace splits tokens.
    ///   * Single quotes preserve their contents verbatim (no escapes inside).
    ///   * Double quotes preserve whitespace; `\"`, `\\`, `\$` are escaped.
    ///   * A backslash outside quotes escapes the next character.
    ///   * No variable expansion, no globbing.
    public static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var i = input.startIndex
        var hasCurrent = false

        func flush() {
            if hasCurrent {
                tokens.append(current)
                current = ""
                hasCurrent = false
            }
        }

        while i < input.endIndex {
            let c = input[i]

            if inSingle {
                if c == "'" {
                    inSingle = false
                } else {
                    current.append(c)
                    hasCurrent = true
                }
            } else if inDouble {
                if c == "\\" {
                    let next = input.index(after: i)
                    if next < input.endIndex {
                        let nc = input[next]
                        if nc == "\"" || nc == "\\" || nc == "$" || nc == "`" {
                            current.append(nc)
                            hasCurrent = true
                            i = next
                        } else {
                            current.append(c)
                            hasCurrent = true
                        }
                    } else {
                        current.append(c)
                        hasCurrent = true
                    }
                } else if c == "\"" {
                    inDouble = false
                } else {
                    current.append(c)
                    hasCurrent = true
                }
            } else {
                if c.isWhitespace {
                    flush()
                } else if c == "'" {
                    inSingle = true
                    hasCurrent = true   // empty quoted string still produces an arg
                } else if c == "\"" {
                    inDouble = true
                    hasCurrent = true
                } else if c == "\\" {
                    let next = input.index(after: i)
                    if next < input.endIndex {
                        current.append(input[next])
                        hasCurrent = true
                        i = next
                    }
                } else {
                    current.append(c)
                    hasCurrent = true
                }
            }
            i = input.index(after: i)
        }
        flush()
        return tokens
    }
}
