// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TriageXRCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TriageXRCore", targets: ["TriageXRCore"])
    ],
    targets: [
        .target(
            name: "TriageXRCore",
            path: "Core"
        ),
        .testTarget(
            name: "TriageXRCoreTests",
            dependencies: ["TriageXRCore"],
            path: "Tests/TriageXRCoreTests"
        )
    ]
)
