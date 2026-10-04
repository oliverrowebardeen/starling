// swift-tools-version: 6.2
// Change the plan: suggest a new time, activity, or friend for a confirmed
// plan, or leave it (ADR 0022). Owned by lane P15-E (Chaining and audit).

import PackageDescription

let package = Package(
    name: "ChangePlan",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingChangePlan", targets: ["StarlingChangePlan"]),
    ],
    dependencies: [
        .package(path: "../../StarlingCore"),
        // Test only: chain starts and the audit, for the multi-phone transcripts.
        .package(path: "../../StarlingChaining"),
        .package(path: "../../StarlingPolicy"),
    ],
    targets: [
        .target(name: "StarlingChangePlan", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .testTarget(
            name: "StarlingChangePlanTests",
            dependencies: [
                "StarlingChangePlan",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingChaining", package: "StarlingChaining"),
                .product(name: "StarlingPolicy", package: "StarlingPolicy"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
