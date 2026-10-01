// swift-tools-version: 6.2
// PickAPlace: the Pick a place skill (ADRs 0010 to 0014). Owned by lane P15-D.
// The library is Foundation and StarlingCore only, so every rule is tested
// with fakes.

import PackageDescription

let package = Package(
    name: "PickAPlace",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "PickAPlace", targets: ["PickAPlace"]),
    ],
    dependencies: [
        .package(path: "../../StarlingCore"),
        // Test only: LoopbackHub for group flows, and the real policy engine
        // for privacy topics. The library itself sends through Outbox only.
        .package(path: "../../StarlingTransport"),
        .package(path: "../../StarlingPolicy"),
    ],
    targets: [
        .target(name: "PickAPlace", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .testTarget(
            name: "PickAPlaceTests",
            dependencies: [
                "PickAPlace",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingTransport", package: "StarlingTransport"),
                .product(name: "StarlingPolicy", package: "StarlingPolicy"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
