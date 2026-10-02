// swift-tools-version: 6.2
// DownFor: the Down for... skill (Phase 1.5, ADR 0010). Its descriptor, its
// SkillService over the app's Outbox and Inbox, and the template proposal
// sentence. Owned by lane P15-B.

import PackageDescription

let package = Package(
    name: "DownFor",
    platforms: [
        .iOS("27.0"),
        .macOS(.v26),
    ],
    products: [
        .library(name: "DownFor", targets: ["DownFor"]),
    ],
    dependencies: [
        .package(path: "../../StarlingCore"),
        .package(path: "../../StarlingNegotiation"),
        // Test only: LoopbackHub for end-to-end flows, and the real policy
        // engine for one flow. The library never touches a Transport.
        .package(path: "../../StarlingTransport"),
        .package(path: "../../StarlingPolicy"),
    ],
    targets: [
        .target(
            name: "DownFor",
            dependencies: [
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingNegotiation", package: "StarlingNegotiation"),
            ]
        ),
        .testTarget(
            name: "DownForTests",
            dependencies: [
                "DownFor",
                .product(name: "StarlingCore", package: "StarlingCore"),
                .product(name: "StarlingFakes", package: "StarlingCore"),
                .product(name: "StarlingTransport", package: "StarlingTransport"),
                .product(name: "StarlingPolicy", package: "StarlingPolicy"),
            ]
        ),
    ]
)
