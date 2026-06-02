import Foundation
import ImageGlassCore

let args = Array(CommandLine.arguments.dropFirst())
let exitCode = IgCmdDispatcher().run(arguments: args)
exit(exitCode)
