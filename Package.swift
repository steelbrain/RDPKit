// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RDPKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
        .tvOS(.v17),
        .macCatalyst(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "RDPKit",
            targets: ["RDPKit"]
        ),
        // AppKit views and keyboard mapping for a macOS client; empty on other platforms.
        .library(
            name: "RDPKitAppKit",
            targets: ["RDPKitAppKit"]
        ),
        // In-memory stand-ins for a server, for an application's own tests.
        .library(
            name: "RDPKitTesting",
            targets: ["RDPKitTesting"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.1"),
    ],
    targets: [
        .target(
            name: "RDPKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "RDPKitAppKit",
            dependencies: ["RDPKit"]
        ),
        .target(
            name: "RDPKitTesting",
            dependencies: [
                "RDPKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
        // Stops a test process whose memory grows without bound; every test target links it.
        .target(
            name: "RDPKitTestMemoryLimit",
            path: "Tests/RDPKitTestMemoryLimit"
        ),
        .testTarget(
            name: "RDPKitTests",
            dependencies: [
                "RDPKit",
                "RDPKitTesting",
                "RDPKitTestMemoryLimit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "RDPKitAppKitTests",
            dependencies: ["RDPKit", "RDPKitAppKit", "RDPKitTesting", "RDPKitTestMemoryLimit"]
        ),
    ]
)
