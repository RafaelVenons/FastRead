// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FastRead",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FastReadCore", targets: ["FastReadCore"])
    ],
    targets: [
        .target(name: "FastReadCore"),
        .testTarget(name: "FastReadCoreTests", dependencies: ["FastReadCore"]),
    ]
)
