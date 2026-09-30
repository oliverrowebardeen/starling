// swift-tools-version: 6.2
// StarlingTransport: Transport implementations. Owned by the Transport lane.
// Wi-Fi Aware (Phase 1, Identity lane) and Relay (Phase 2) arrive as more targets.

import PackageDescription

let package = Package(
    name: "StarlingTransport",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingTransport", targets: ["StarlingTransport"]),
        .library(name: "StarlingLocalP2P", targets: ["StarlingLocalP2P"]),
        .library(name: "StarlingWiFiAware", targets: ["StarlingWiFiAware"]),
    ],
    dependencies: [
        .package(path: "../StarlingCore"),
    ],
    targets: [
        .target(name: "StarlingTransport", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .target(name: "StarlingLocalP2P", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .target(
            name: "StarlingWiFiAware",
            dependencies: ["StarlingLocalP2P", .product(name: "StarlingCore", package: "StarlingCore")]
        ),
        .testTarget(
            name: "StarlingLocalP2PTests",
            dependencies: ["StarlingLocalP2P", .product(name: "StarlingCore", package: "StarlingCore")]
        ),
        .testTarget(
            name: "StarlingWiFiAwareTests",
            dependencies: ["StarlingWiFiAware", "StarlingLocalP2P", .product(name: "StarlingCore", package: "StarlingCore")]
        ),
        .testTarget(
            name: "StarlingTransportTests",
            dependencies: [
                "StarlingTransport",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
            ]
        ),
    ]
)
