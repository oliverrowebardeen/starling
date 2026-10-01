// swift-tools-version: 6.2
// FindATime: the Find a time skill (Phase 1.5, ADR 0010). Agrees on a time
// with friends' agents across the calendar and no-calendar gap (brief 2.3).
// Owned by lane P15-C.

import PackageDescription

let package = Package(
    name: "FindATime",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "FindATime", targets: ["FindATime"]),
    ],
    dependencies: [
        .package(path: "../../StarlingCore"),
        .package(path: "../../StarlingAvailability"),
        // Test only: Loopback for end-to-end flows and the real policy for
        // consent. The library sends through Outbox and never holds a Transport.
        .package(path: "../../StarlingTransport"),
        .package(path: "../../StarlingPolicy"),
    ],
    targets: [
        .target(
            name: "FindATime",
            dependencies: [
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingAvailability", package: "StarlingAvailability"),
            ]
        ),
        .testTarget(
            name: "FindATimeTests",
            dependencies: [
                "FindATime",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingAvailability", package: "StarlingAvailability"),
                .product(name: "StarlingAvailabilityFakes", package: "StarlingAvailability"),
                .product(name: "StarlingTransport", package: "StarlingTransport"),
                .product(name: "StarlingPolicy", package: "StarlingPolicy"),
            ]
        ),
    ]
)
