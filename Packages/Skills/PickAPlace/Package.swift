// swift-tools-version: 6.2
// PickAPlace: the Pick a place skill (ADRs 0010 to 0014). Owned by lane P15-D.
// - PickAPlace: Foundation and StarlingCore only, so every rule is tested
//   with fakes.
// - PickAPlaceMapKit: Apple Maps search and Core Location behind the
//   PickAPlace protocols, for the app to compose.

import PackageDescription

let package = Package(
    name: "PickAPlace",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "PickAPlace", targets: ["PickAPlace"]),
        .library(name: "PickAPlaceMapKit", targets: ["PickAPlaceMapKit"]),
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
        .target(name: "PickAPlaceMapKit", dependencies: ["PickAPlace", .product(name: "StarlingCore", package: "StarlingCore")]),
        .testTarget(
            name: "PickAPlaceTests",
            dependencies: [
                "PickAPlace",
                "PickAPlaceMapKit",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingTransport", package: "StarlingTransport"),
                .product(name: "StarlingPolicy", package: "StarlingPolicy"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
