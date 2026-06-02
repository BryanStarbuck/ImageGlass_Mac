// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ImageGlass",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ImageGlass", targets: ["ImageGlass"]),
        .executable(name: "imageglass-mcp", targets: ["ImageGlassMCPServer"]),
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
    ]
)
