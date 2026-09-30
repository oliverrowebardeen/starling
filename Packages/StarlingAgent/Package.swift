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
        .executableTarget(name: "agent-bench", dependencies: ["StarlingAgent", "StarlingAgentBench"]),
        .testTarget(
            name: "StarlingAgentTests",
            dependencies: [
                "StarlingAgent",
                "StarlingAgentBench",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
            ]
        ),
    ]
)
