 // swift-tools-version:5.10
 import PackageDescription

 let package = Package(
    name: "CoreMesh",
    platforms: [
        .iOS(.v16), .macOS(.v13),
    ],
     products: [
         .library(name: "CoreMesh", targets: ["CoreMesh"]),
     ],
    dependencies: [
        // Cross-platform replacement for CryptoKit
        .package(url: "https://github.com/apple/swift-crypto.git", from: "2.0.0")
    ],
     targets: [
        .target(
            name: "CoreMesh",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
         .testTarget(name: "CoreMeshTests", dependencies: ["CoreMesh"]),
     ]
 )
