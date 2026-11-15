// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TinyUsage",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TinyUsage", targets: ["TinyUsage"]),
        // Gives the library its own scheme; Xcode renders previews with it.
        .library(name: "TinyUsageCore", targets: ["TinyUsageCore"]),
        .executable(name: "TinyUsageCapture", targets: ["TinyUsageCapture"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .executableTarget(name: "TinyUsageCapture"),
        // All app code lives in a library so Xcode Previews (and the RenderPreview MCP tool) can
        // render its views: previews of executable targets need ENABLE_DEBUG_DYLIB, which a
        // package can't set. The executable is only the entry point.
        .target(
            name: "TinyUsageCore",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "TinyUsage",
            dependencies: ["TinyUsageCore"],
            // Sparkle.framework ships in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "TinyUsageCoreTests", dependencies: ["TinyUsageCore"])
    ]
)
