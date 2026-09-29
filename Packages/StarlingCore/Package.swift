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
        // Deterministic test doubles every lane tests against. Includes the
        // insecure PSI stub, so release builds must not ship it.
        .library(name: "StarlingFakes", targets: ["StarlingFakes"]),
    ],
    targets: [
        .target(name: "StarlingCore"),
        .target(name: "StarlingFakes", dependencies: ["StarlingCore"]),
        .testTarget(name: "StarlingCoreTests", dependencies: ["StarlingCore", "StarlingFakes"]),
        .testTarget(name: "StarlingFakesTests", dependencies: ["StarlingCore", "StarlingFakes"]),
    ]
)
