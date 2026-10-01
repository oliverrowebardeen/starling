// swift-tools-version: 6.2
// StarlingChaining: "Keep it going" chain suggestions, per-link consent,
// time-triggered chains, the plan timeline, and "What left your phone".
// Owned by lane P15-E (Chaining and audit).

import PackageDescription

let package = Package(
    name: "StarlingChaining",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingChaining", targets: ["StarlingChaining"]),
    ],
    dependencies: [
        .package(path: "../StarlingCore"),
    ],
    targets: [
        .target(name: "StarlingChaining", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .testTarget(
            name: "StarlingChainingTests",
            dependencies: [
                "StarlingChaining",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
