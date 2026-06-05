import Foundation
import ImageGlassCore

let args = Array(CommandLine.arguments.dropFirst())
// docs/performance.mdx §5.6 / §10.12 — `Igcmd.Dispatch` wraps the full
// CLI invocation so we can see total wallclock per subcommand. The
// subcommand name is the dominant `extra` payload — analyzer groups by
// it. `(none)` is used when the user ran `igcmd` with no arguments
// (which falls through to `printTopLevelHelp`).
let _dispatchTrace = PerformanceLog.shared.start(
    "Igcmd.Dispatch",
    extra: [("subcommand", args.first ?? "(none)")]
)
let exitCode = IgCmdDispatcher().run(arguments: args)
_dispatchTrace.finish(extra: [("exit", String(exitCode))])
exit(exitCode)
