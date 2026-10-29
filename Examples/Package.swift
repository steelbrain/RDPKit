// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RDPKitExamples",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "RDPClient",
            targets: ["RDPClient"]
        ),
        .executable(
            name: "RDPFirstFrameCapture",
            targets: ["RDPFirstFrameCapture"]
        ),
        .executable(
            name: "RDPFrameBenchmark",
            targets: ["RDPFrameBenchmark"]
        ),
        .executable(
            name: "RDPPreflight",
            targets: ["RDPPreflight"]
        ),
    ],
    dependencies: [
        .package(name: "RDPKit", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "RDPClient",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
            ],
            path: "RDPClient/Sources"
        ),
        .target(
            name: "RDPCommandLineSupport",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
            ],
            path: "RDPCommandLineSupport"
        ),
        .executableTarget(
            name: "RDPFirstFrameCapture",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
                "RDPCommandLineSupport",
            ],
            path: "RDPFirstFrameCapture"
        ),
        .executableTarget(
            name: "RDPFrameBenchmark",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
                "RDPCommandLineSupport",
            ],
            path: "RDPFrameBenchmark"
        ),
        .executableTarget(
            name: "RDPPreflight",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
                "RDPCommandLineSupport",
            ],
            path: "RDPPreflight"
        ),
        .testTarget(
            name: "RDPCommandLineToolTests",
            dependencies: [
                "RDPCommandLineSupport",
                "RDPFirstFrameCapture",
                "RDPFrameBenchmark",
                "RDPPreflight",
            ],
            path: "Tests/RDPCommandLineToolTests"
        ),
        .testTarget(
            name: "RDPClientTests",
            dependencies: [
                "RDPClient",
            ],
            path: "Tests/RDPClientTests"
        ),
    ]
)
