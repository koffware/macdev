// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacDev",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacDev", targets: ["MacDev"])],
    targets: [
        .target(name: "MacDevCore"),
        .executableTarget(name: "MacDev", dependencies: ["MacDevCore"], resources: [.process("Resources")]),
        .testTarget(name: "MacDevCoreTests", dependencies: ["MacDevCore"]),
        .testTarget(name: "MacDevTests", dependencies: ["MacDev", "MacDevCore"]),
    ]
)
