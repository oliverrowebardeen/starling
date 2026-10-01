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
        // Used only by the opt-in prompt-injection test target.
        .package(path: "../../Packages/StarlingAgent"),
        // Production implementations used only by integration tests.
        .package(path: "../../Packages/StarlingNegotiation"),
        .package(path: "../../Packages/StarlingPolicy"),
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
        .testTarget(name: "PromptInjectionTests", dependencies: [
            .product(name: "StarlingCore", package: "StarlingCore"),
            .product(name: "StarlingFakes", package: "StarlingCore"),
            .product(name: "StarlingAgent", package: "StarlingAgent"),
        ], resources: [.copy("Results")]),
        .testTarget(name: "DownIntegrationTests", dependencies: [
            "SimulatorKit",
            .product(name: "StarlingCore", package: "StarlingCore"),
            .product(name: "StarlingFakes", package: "StarlingCore"),
            .product(name: "StarlingTransport", package: "StarlingTransport"),
            .product(name: "StarlingNegotiation", package: "StarlingNegotiation"),
            .product(name: "StarlingPolicy", package: "StarlingPolicy"),
        ]),
    ]
)
