import SwiftUI
import ImageGlassCore

@main
struct ImageGlassApp: App {
    @State private var state: AppState

    init() {
        let s = AppState()
        // Parse `/Name=Value` overrides and positional file args at launch.
        // `CommandLine.arguments[0]` is the program path, so skip it.
        let parsed = ImageGlassLaunchArguments.parse(CommandLine.arguments)
        s.applyLaunchArguments(parsed)
        _state = State(wrappedValue: s)
    }

    var body: some Scene {
        WindowGroup("ImageGlass") {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Re-evaluate Active Scope") {
                    Task { await state.reevaluateActive() }
                }
                .keyboardShortcut("R", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) { }
        }
    }
}
