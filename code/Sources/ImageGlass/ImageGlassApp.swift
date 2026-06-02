import SwiftUI
import ImageGlassCore

@main
struct ImageGlassApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("ImageGlass") {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
