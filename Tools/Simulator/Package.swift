// swift-tools-version: 6.2
// N-agent simulation over the Loopback transport.
// Owned by the Transport lane, except Scenarios/ and test targets (red team lane).

import PackageDescription

let package = Package(
    name: "Simulator",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "starling-sim", targets: ["starling-sim"]),
        .library(name: "SimulatorKit", targets: ["SimulatorKit"]),
    ],
    dependencies: [
        .package(path: "../../Packages/StarlingCore"),
        .package(path: "../../Packages/StarlingTransport"),
    ],
    targets: [
        .target(
            name: "SimulatorKit",
            dependencies: [
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingTransport", package: "StarlingTransport"),
            ]
        ),
        .target(
            name: "Scenarios",
            dependencies: ["SimulatorKit", .product(name: "StarlingTransport", package: "StarlingTransport")],
            path: "Scenarios"
        ),
        .executableTarget(name: "starling-sim", dependencies: ["SimulatorKit", "Scenarios"]),
        .testTarget(name: "SimulatorKitTests", dependencies: ["SimulatorKit"]),
        .testTarget(name: "ScenarioTests", dependencies: ["Scenarios", "SimulatorKit"]),
    ]
)
