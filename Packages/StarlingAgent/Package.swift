// swift-tools-version: 6.2
// StarlingAgent: the FoundationModels implementation of AgentModel, plus the
// Phase 0 token and latency bench. Owned by the Agent lane.

import PackageDescription

let package = Package(
    name: "StarlingAgent",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingAgent", targets: ["StarlingAgent"]),
        .library(name: "StarlingAgentBench", targets: ["StarlingAgentBench"]),
        .executable(name: "agent-bench", targets: ["agent-bench"]),
    ],
    dependencies: [
        .package(path: "../StarlingCore"),
    ],
    targets: [
        .target(name: "StarlingAgent", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .target(
            name: "StarlingAgentBench",
            dependencies: ["StarlingAgent", .product(name: "StarlingCore", package: "StarlingCore")]
        ),
        // SampleSkills stands in for the skill packages' descriptors, which
        // StarlingAgent must not depend on. The bench library itself stays
        // free of fakes, since the app's Debug bench links it.
        .executableTarget(name: "agent-bench", dependencies: [
            "StarlingAgent", "StarlingAgentBench", .product(name: "StarlingFakes", package: "StarlingCore"),
        ]),
        .testTarget(
            name: "StarlingAgentTests",
            dependencies: [
                "StarlingAgent",
                "StarlingAgentBench",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
            ]
        ),
        // Evaluations framework suites (iOS and macOS 27, Xcode 27). A
        // separate target so only these files import Evaluations.
        .testTarget(
            name: "StarlingAgentEvaluations",
            dependencies: [
                "StarlingAgent",
                "StarlingAgentBench",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
            ]
        ),
    ]
)
