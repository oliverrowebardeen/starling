// swift-tools-version: 6.2
// StarlingCore: shared protocols, message types, and identifiers.
// Owned by the Orchestrator. Lanes request changes in docs/requests/.

import PackageDescription

let package = Package(
    name: "StarlingCore",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingCore", targets: ["StarlingCore"]),
    ],
    targets: [
        .target(name: "StarlingCore"),
        .testTarget(name: "StarlingCoreTests", dependencies: ["StarlingCore"]),
    ]
)
