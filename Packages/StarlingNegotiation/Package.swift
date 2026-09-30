// swift-tools-version: 6.2
// StarlingNegotiation: negotiation building blocks and the Down? feature.
// Owned by the Negotiation lane (F).

import PackageDescription

let package = Package(
    name: "StarlingNegotiation",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "StarlingNegotiation", targets: ["StarlingNegotiation"]),
    ],
    dependencies: [
        .package(path: "../StarlingCore"),
        // Test only: LoopbackHub for end-to-end flows. The library itself
        // never touches a Transport; it sends through Outbox.
        .package(path: "../StarlingTransport"),
    ],
    targets: [
        .target(name: "StarlingNegotiation", dependencies: [.product(name: "StarlingCore", package: "StarlingCore")]),
        .testTarget(
            name: "StarlingNegotiationTests",
            dependencies: [
                "StarlingNegotiation",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingTransport", package: "StarlingTransport"),
            ]
        ),
    ]
)
