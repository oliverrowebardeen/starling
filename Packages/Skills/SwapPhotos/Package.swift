// swift-tools-version: 6.2
// Swap photos: a flagged-off skill that proves the after-plan-ends chain
// hook (Phase 1.5, ADR 0012). Owned by lane P15-E (Chaining and audit).

import PackageDescription

let package = Package(
    name: "SwapPhotos",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingSwapPhotos", targets: ["StarlingSwapPhotos"]),
    ],
    dependencies: [
        .package(path: "../../StarlingCore"),
        // Test only: the chain scheduler, egress recorder, and real policy,
        // to run the after-plan-ends hook end to end.
        .package(path: "../../StarlingChaining"),
        .package(path: "../../StarlingPolicy"),
    ],
    targets: [
        .target(name: "StarlingSwapPhotos", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .testTarget(
            name: "StarlingSwapPhotosTests",
            dependencies: [
                "StarlingSwapPhotos",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingChaining", package: "StarlingChaining"),
                .product(name: "StarlingPolicy", package: "StarlingPolicy"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
