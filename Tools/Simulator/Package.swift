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
        // Lane E1's secure channel, for LinkSecurity.secureChannel (issue #8).
        .package(path: "../../Packages/StarlingIdentity"),
        // Used only by the opt-in prompt-injection test target.
        .package(path: "../../Packages/StarlingAgent"),
        // Production implementations used only by integration tests.
        .package(path: "../../Packages/StarlingNegotiation"),
        .package(path: "../../Packages/StarlingPolicy"),
        // P15-F exercises actual consent and pairing presentation in tests.
        .package(path: "../../App/Features"),
        .package(path: "../../Packages/Skills/PickAPlace"),
        .package(path: "../../Packages/StarlingChaining"),
        .package(path: "../../Packages/Skills/SwapPhotos"),
        .package(path: "../../Packages/Skills/FindATime"),
        .package(path: "../../Packages/StarlingAvailability"),
        .package(path: "../../Packages/Skills/DownFor"),
        .package(path: "../../Packages/Skills/ChangePlan"),
    ],
    targets: [
        .target(
            name: "SimulatorKit",
            dependencies: [
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingTransport", package: "StarlingTransport"),
                .product(name: "StarlingIdentity", package: "StarlingIdentity"),
            ]
        ),
        .target(
            name: "Scenarios",
            dependencies: ["SimulatorKit", .product(name: "StarlingTransport", package: "StarlingTransport")],
            path: "Scenarios"
        ),
        .executableTarget(name: "starling-sim", dependencies: ["SimulatorKit", "Scenarios"]),
        .testTarget(name: "SimulatorKitTests", dependencies: [
            "SimulatorKit", "Scenarios",
            .product(name: "StarlingIdentity", package: "StarlingIdentity"),
        ]),
        .testTarget(name: "ScenarioTests", dependencies: ["Scenarios", "SimulatorKit"]),
        .testTarget(name: "PromptInjectionTests", dependencies: [
            .product(name: "StarlingCore", package: "StarlingCore"),
            .product(name: "StarlingFakes", package: "StarlingCore"),
            .product(name: "StarlingAgent", package: "StarlingAgent"),
        ], resources: [.copy("Results")]),
        .testTarget(name: "DownIntegrationTests", dependencies: [
            "SimulatorKit", "Scenarios",
            .product(name: "StarlingCore", package: "StarlingCore"),
            .product(name: "StarlingFakes", package: "StarlingCore"),
            .product(name: "StarlingTransport", package: "StarlingTransport"),
            .product(name: "StarlingNegotiation", package: "StarlingNegotiation"),
            .product(name: "StarlingPolicy", package: "StarlingPolicy"),
        ]),
        .testTarget(name: "Phase15RedTeamTests", dependencies: [
            "Scenarios", "SimulatorKit",
            .product(name: "StarlingCore", package: "StarlingCore"),
            .product(name: "StarlingFakes", package: "StarlingCore"),
            .product(name: "StarlingAgent", package: "StarlingAgent"),
            .product(name: "StarlingPolicy", package: "StarlingPolicy"),
            .product(name: "StarlingFeatures", package: "Features"),
            .product(name: "PickAPlace", package: "PickAPlace"),
            .product(name: "StarlingChaining", package: "StarlingChaining"),
            .product(name: "StarlingSwapPhotos", package: "SwapPhotos"),
            .product(name: "FindATime", package: "FindATime"),
            .product(name: "StarlingAvailabilityFakes", package: "StarlingAvailability"),
            .product(name: "DownFor", package: "DownFor"),
            .product(name: "StarlingChangePlan", package: "ChangePlan"),
            .product(name: "StarlingNegotiation", package: "StarlingNegotiation"),
        ]),
    ]
)
