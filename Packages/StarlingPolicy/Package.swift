// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StarlingPolicy",
    platforms: [.iOS("27.0"), .macOS(.v26)],
    products: [.library(name: "StarlingPolicy", targets: ["StarlingPolicy"])],
    dependencies: [
        .package(path: "../StarlingCore"),
        .package(path: "../StarlingTransport"),
    ],
    targets: [
        .target(name: "StarlingPolicy", dependencies: [
            .product(name: "StarlingCore", package: "StarlingCore"),
        ]),
        .testTarget(name: "StarlingPolicyTests", dependencies: [
            "StarlingPolicy",
            .product(name: "StarlingFakes", package: "StarlingCore"),
            .product(name: "StarlingTransport", package: "StarlingTransport"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
