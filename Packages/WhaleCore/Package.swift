// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhaleCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WhaleCore", targets: ["WhaleCore"])],
    targets: [
        .target(name: "WhaleCore"),
        .testTarget(name: "WhaleCoreTests", dependencies: ["WhaleCore"])
    ]
)
