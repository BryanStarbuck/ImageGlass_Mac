import SwiftUI
import ImageGlassCore

@main
struct ImageGlassApp: App {
    @State private var state = AppState()
    @State private var layout = LayoutController()

    var body: some Scene {
        WindowGroup("ImageGlass") {
            ContentView(state: state, layout: layout)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // Wire built-in view factories before bootstrapping the
                    // controller — the controller's bootstrap registers the
                    // descriptors and applies the active preset, which will
                    // immediately query the view registry for factories.
                    registerBuiltinViewFactories(state: state)
                    await layout.bootstrap(builtinDescriptors: BuiltinPanels.all)
                }
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Re-evaluate Active Scope") {
                    Task { await state.reevaluateActive() }
                }
                .keyboardShortcut("R", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) { }
            layoutMenuCommands
        }
    }

    @CommandsBuilder
    private var layoutMenuCommands: some Commands {
        CommandMenu("Layout") {
            ForEach(Array(layout.document.allPresetsInDisplayOrder.prefix(9).enumerated()), id: \.element.id) { idx, preset in
                Button(preset.name) {
                    Task { await layout.applyPreset(named: preset.id) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command, .option])
            }
        }
    }
}

/// Maps panel descriptor ids to their SwiftUI factories. Other agents add
/// entries here (or call `PanelViewRegistry.shared.register` from elsewhere)
/// as they bring their panels online.
@MainActor
private func registerBuiltinViewFactories(state: AppState) {
    let registry = PanelViewRegistry.shared

    // The initial panel — the existing Directory/Filename panel.
    let dirFn: () -> AnyView = { AnyView(DirectoryFilenamePanel(state: state)) }
    registry.register(id: BuiltinPanels.directoryFilename.id, dirFn)

    // Spec presets reference `file_panel` and `file_tree`; until sibling
    // agents ship dedicated panels, point both at the existing combined view
    // so the default "browser" preset renders something useful.
    registry.register(id: BuiltinPanels.filePanel.id, dirFn)
    registry.register(id: BuiltinPanels.fileTree.id, dirFn)
}
