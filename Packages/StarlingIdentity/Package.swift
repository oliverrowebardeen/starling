// swift-tools-version: 6.2
// StarlingIdentity: device identity keys, pinned friends, pairing, and the
// Noise secure channel (ADR 0003). Owned by lane E1.
// Apple frameworks only (CryptoKit, Security); no third-party dependencies.

import PackageDescription

let package = Package(
    name: "StarlingIdentity",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingIdentity", targets: ["StarlingIdentity"]),
    ],
    dependencies: [
        .package(path: "../StarlingCore"),
        // Test-only: the Loopback transport for adversarial tests.
        .package(path: "../StarlingTransport"),
    ],
    targets: [
        .target(name: "StarlingIdentity", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .testTarget(
            name: "StarlingIdentityTests",
            dependencies: [
                "StarlingIdentity",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingTransport", package: "StarlingTransport"),
            ],
            resources: [.copy("Vectors")]
        ),
    ]
)
