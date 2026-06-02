import SwiftUI

// Minimal @main entry so the `ImageGlass` executable target links at this
// scaffold commit. The themes / panels / viewer agents own the real
// ImageGlassApp / ContentView; this file exists so XCTest in
// ImageGlassCoreTests can be built (SwiftPM links all executables before
// running any test). When a richer ImageGlassApp lands, replace this
// stub.

@main
struct ImageGlassApp: App {
    var body: some Scene {
        WindowGroup("ImageGlass") {
            ContentViewStub()
        }
    }
}

struct ContentViewStub: View {
    var body: some View {
        Text("ImageGlass — scaffold")
            .padding()
    }
}
