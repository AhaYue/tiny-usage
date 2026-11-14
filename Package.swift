// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TinyUsage",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TinyUsage", targets: ["Mimir"]),
        .executable(name: "TinyUsageCapture", targets: ["TinyUsageCapture"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(name: "TinyUsageCapture"),
        .executableTarget(
            name: "Mimir",
            exclude: ["Mimir.entitlements"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "MimirTests", dependencies: ["Mimir"])
    ]
)
