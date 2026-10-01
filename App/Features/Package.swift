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
        // Lane E's chaining and audit, and lane D's Pick a place (its
        // Foundation-only library; the MapKit half stays in the app).
        .package(path: "../../Packages/StarlingChaining"),
        .package(path: "../../Packages/Skills/PickAPlace"),
    ],
    targets: [
        // StarlingFakes is for tests and Debug builds; the app injects
        // fakes, this module never imports them.
        .target(name: "StarlingFeatures", dependencies: [
            .product(name: "StarlingCore", package: "StarlingCore"),
            .product(name: "StarlingChaining", package: "StarlingChaining"),
            .product(name: "PickAPlace", package: "PickAPlace"),
        ]),
        .testTarget(
            name: "StarlingFeaturesTests",
            dependencies: [
                "StarlingFeatures",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
            ]
        ),
    ]
)
