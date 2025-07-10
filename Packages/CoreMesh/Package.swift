// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CoreMesh",
    platforms: [
        // future-proof, but has no effect on Windows
        .iOS(.v16), .macOS(.v13)
    ],
    products: [
        .library(name: "CoreMesh", targets: ["CoreMesh"]),
    ],
    targets: [
        .target(name: "CoreMesh"),
        .testTarget(name: "CoreMeshTests", dependencies: ["CoreMesh"]),
    ]
)
