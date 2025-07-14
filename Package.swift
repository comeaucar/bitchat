// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "bitchat",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "bitchat",
            targets: ["bitchat"]
        ),
        .executable(
            name: "bitchat-cli",
            targets: ["bitchat-cli"]
        ),
    ],
    dependencies: [
        // Local CoreMesh package
        .package(path: "./Packages/CoreMesh"),
    ],
    targets: [
        .executableTarget(
            name: "bitchat",
            dependencies: [
                .product(name: "CoreMesh", package: "CoreMesh")
            ],
            path: "bitchat"
        ),
        .executableTarget(
            name: "bitchat-cli",
            dependencies: [
                .product(name: "CoreMesh", package: "CoreMesh")
            ],
            path: "Sources/bitchat-cli"
        ),
    ]
)