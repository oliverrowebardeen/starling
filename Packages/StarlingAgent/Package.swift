// swift-tools-version: 6.2
// StarlingAgent: the FoundationModels implementation of AgentModel. Owned by the Agent lane.

import PackageDescription

let package = Package(
    name: "StarlingAgent",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingAgent", targets: ["StarlingAgent"]),
    ],
    dependencies: [
        .package(path: "../StarlingCore"),
    ],
    targets: [
        .target(name: "StarlingAgent", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .testTarget(
            name: "StarlingAgentTests",
            dependencies: [
                "StarlingAgent",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
            ]
        ),
    ]
)
