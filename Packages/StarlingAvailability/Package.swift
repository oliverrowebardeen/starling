// swift-tools-version: 6.2
// StarlingAvailability: where an owner's free time comes from. An EventKit
// source that reads busy and free only, a stated-intent source, and the
// ask-owner fallback, all producing `[TimeSlot]` (brief 2.3, ADR 0013).
// Owned by lane P15-C.

import PackageDescription

let package = Package(
    name: "StarlingAvailability",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingAvailability", targets: ["StarlingAvailability"]),
        // A calendar store double with event titles, places, and people, so
        // tests can prove those never leave the source. Tests and previews only.
        .library(name: "StarlingAvailabilityFakes", targets: ["StarlingAvailabilityFakes"]),
    ],
    dependencies: [
        .package(path: "../StarlingCore"),
    ],
    targets: [
        .target(name: "StarlingAvailability", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .target(
            name: "StarlingAvailabilityFakes",
            dependencies: ["StarlingAvailability", .product(name: "StarlingCore", package: "StarlingCore")]
        ),
        .testTarget(
            name: "StarlingAvailabilityTests",
            dependencies: [
                "StarlingAvailability",
                "StarlingAvailabilityFakes",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
            ]
        ),
    ]
)
