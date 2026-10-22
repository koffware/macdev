// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacDev",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacDev", targets: ["MacDev"])],
    targets: [
        .target(name: "MacDevCore"),
        .executableTarget(name: "MacDev", dependencies: ["MacDevCore"]),
        .testTarget(name: "MacDevCoreTests", dependencies: ["MacDevCore"]),
    ]
)
