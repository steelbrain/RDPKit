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
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "RDPClient",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
            ],
            path: "RDPClient/Sources"
        ),
        .executableTarget(
            name: "RDPFirstFrameCapture",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
                "RDPFirstFrameCaptureSupport",
            ],
            path: "RDPFirstFrameCapture"
        ),
        .target(
            name: "RDPFirstFrameCaptureSupport",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
            ],
            path: "RDPFirstFrameCaptureSupport"
        ),
        .executableTarget(
            name: "RDPFrameBenchmark",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
            ],
            path: "RDPFrameBenchmark"
        ),
        .executableTarget(
            name: "RDPPreflight",
            dependencies: [
                .product(name: "RDPKit", package: "RDPKit"),
            ],
            path: "RDPPreflight"
        ),
        .testTarget(
            name: "RDPFirstFrameCaptureSupportTests",
            dependencies: [
                "RDPFirstFrameCaptureSupport",
            ],
            path: "Tests/RDPFirstFrameCaptureSupportTests"
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
