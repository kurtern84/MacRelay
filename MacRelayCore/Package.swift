// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacRelayCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "MacRelayCore", targets: ["MacRelayCore"])
    ],
    targets: [
        .target(name: "MacRelayCore"),
        .testTarget(name: "MacRelayCoreTests", dependencies: ["MacRelayCore"])
    ]
)
