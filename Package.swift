// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AYUsage",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AYUsage", targets: ["Mimir"]),
        .executable(name: "AYUsageCapture", targets: ["AYUsageCapture"])
    ],
    dependencies: [],
    targets: [
        .target(name: "MimirShared"),
        .executableTarget(name: "AYUsageCapture"),
        .executableTarget(
            name: "Mimir",
            dependencies: ["MimirShared"],
            exclude: ["Mimir.entitlements"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "MimirTests", dependencies: ["Mimir"])
    ]
)
