// swift-tools-version: 6.2
// starling-peer: a Mac stand-in for a second phone in LocalP2P device tests.
// Owned by the Orchestrator.

import PackageDescription

let package = Package(
    name: "Peer",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "starling-peer", targets: ["starling-peer"]),
    ],
    dependencies: [
        .package(path: "../../Packages/StarlingCore"),
        .package(path: "../../Packages/StarlingTransport"),
    ],
    targets: [
        .target(
            name: "PeerKit",
            dependencies: [
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
            ]
        ),
        .executableTarget(
            name: "starling-peer",
            dependencies: ["PeerKit", .product(name: "StarlingLocalP2P", package: "StarlingTransport")]
        ),
        .testTarget(
            name: "PeerKitTests",
            dependencies: [
                "PeerKit",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingTransport", package: "StarlingTransport"),
            ]
        ),
    ]
)
