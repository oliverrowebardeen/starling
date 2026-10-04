// swift-tools-version: 6.2
// StarlingFeatures: the app's view models and presentation logic, kept out of
// the app target so `swift test` covers them on the Mac. Owned by lane H.
// SwiftUI views stay in App/Sources; nothing here imports SwiftUI or UIKit.

import PackageDescription

let package = Package(
    name: "StarlingFeatures",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingFeatures", targets: ["StarlingFeatures"]),
    ],
    dependencies: [
        .package(path: "../../Packages/StarlingCore"),
        // Lane E's chaining and audit, lane D's Pick a place (its
        // Foundation-only library; the MapKit half stays in the app), and
        // lane C's Find a time with its calendar access, and lane B's Down
        // for... (its copy, template, and request records).
        .package(path: "../../Packages/StarlingChaining"),
        .package(path: "../../Packages/Skills/PickAPlace"),
        .package(path: "../../Packages/Skills/FindATime"),
        .package(path: "../../Packages/Skills/DownFor"),
        // Lane E's Change the plan (ADR 0022, ADR 0243).
        .package(path: "../../Packages/Skills/ChangePlan"),
        .package(path: "../../Packages/StarlingAvailability"),
    ],
    targets: [
        // StarlingFakes is for tests and Debug builds; the app injects
        // fakes, this module never imports them.
        .target(name: "StarlingFeatures", dependencies: [
            .product(name: "StarlingCore", package: "StarlingCore"),
            .product(name: "StarlingChaining", package: "StarlingChaining"),
            .product(name: "PickAPlace", package: "PickAPlace"),
            .product(name: "FindATime", package: "FindATime"),
            .product(name: "DownFor", package: "DownFor"),
            .product(name: "StarlingChangePlan", package: "ChangePlan"),
            .product(name: "StarlingAvailability", package: "StarlingAvailability"),
        ]),
        .testTarget(
            name: "StarlingFeaturesTests",
            dependencies: [
                "StarlingFeatures",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingAvailabilityFakes", package: "StarlingAvailability"),
            ]
        ),
    ]
)
