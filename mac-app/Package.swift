// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ElinkAIBridge",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ElinkAIBridge", targets: ["ElinkAIBridge"])],
    targets: [
        .executableTarget(name: "ElinkAIBridge"),
        .testTarget(name: "ElinkAIBridgeTests", dependencies: ["ElinkAIBridge"]),
    ]
)
