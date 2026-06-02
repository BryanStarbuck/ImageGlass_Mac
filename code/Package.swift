// swift-tools-version: 6.0
//
// SwiftPM manifest for ImageGlass_Mac (Starbuck fork).
//
// Build expectations (see ../docs/build-tools.mdx and ../CLAUDE.md):
//   * Swift tools 5.10+ (required for `swiftLanguageVersions: [.v6]`).
//   * macOS 14 (Sonoma) minimum deployment target.
//   * arm64 + x86_64 universal binary for release distribution
//     (`swift build -c release --arch arm64 --arch x86_64`,
//     wrapped by `just build-universal`).
//   * `ImageGlassCore` is the public Swift SDK third-party tool authors
//     link against to receive `IMAGE_LOADED` events over the IPC channel
//     (the Mac equivalent of the upstream `ImageGlass.Tools` NuGet package
//     described in docs/build-tools.mdx).

import PackageDescription

let package = Package(
    name: "ImageGlass",
    platforms: [.macOS(.v14)],
    products: [
        // SwiftUI viewer app.
        .executable(name: "ImageGlass", targets: ["ImageGlass"]),
        // Standalone MCP server binary (JSON-RPC over stdio).
        .executable(name: "imageglass-mcp", targets: ["ImageGlassMCPServer"]),
        // Public SDK library — depend on this to author a third-party tool
        // that integrates with the viewer (IMAGE_LOADED events, IPC, etc.).
        .library(name: "ImageGlassCore", targets: ["ImageGlassCore"]),
    ],
    targets: [
        .target(
            name: "ImageGlassCore",
            path: "Sources/ImageGlassCore"
        ),
        .executableTarget(
            name: "ImageGlass",
            dependencies: ["ImageGlassCore"],
            path: "Sources/ImageGlass"
        ),
        .executableTarget(
            name: "ImageGlassMCPServer",
            dependencies: ["ImageGlassCore"],
            path: "Sources/ImageGlassMCPServer"
        ),
        .testTarget(
            name: "ImageGlassCoreTests",
            dependencies: ["ImageGlassCore"],
            path: "Tests/ImageGlassCoreTests"
        ),
    ],
    // Pin to Swift 5 language mode for now. Swift 6 strict concurrency
    // would require Sendable annotations on a handful of static lookup
    // tables in Sources/ImageGlassCore/Themes (and similar) before it can
    // be enabled. Bump to `.v6` once those product-code annotations land.
    swiftLanguageModes: [.v5]
)
