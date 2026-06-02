import Foundation
import ImageGlassCore

// `igcmd` — companion command-line utility for ImageGlass. Spec lives at
// docs/command-line.mdx. This file is the dispatcher; each subcommand has
// its own file under Sources/igcmd/.
//
// We intentionally avoid `swift-argument-parser` (or any third-party
// dependency) to keep the package free of new transitive deps.

let dispatcher = IgCmdDispatcher()
let exitCode = dispatcher.run(arguments: CommandLine.arguments)
exit(exitCode)
