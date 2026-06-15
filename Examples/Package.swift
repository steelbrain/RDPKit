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
            ],
            path: "RDPFirstFrameCapture"
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
    ]
)
