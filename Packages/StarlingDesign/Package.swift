// swift-tools-version: 6.2
// StarlingDesign: the Overlap mark as a live SwiftUI status view, its
// geometry, and the brand palette. Owned by the BR (Brand) lane.

import PackageDescription

let package = Package(
    name: "StarlingDesign",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingDesign", targets: ["StarlingDesign"]),
    ],
    targets: [
        .target(name: "StarlingDesign"),
        .testTarget(name: "StarlingDesignTests", dependencies: ["StarlingDesign"]),
    ]
)
