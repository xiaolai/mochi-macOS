// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Mochi", platforms: [.macOS(.v14)], products: [.executable(name: "Mochi", targets: ["MochiApp"])], targets: [
    .target(name: "MochiCore"),
    .executableTarget(name: "MochiApp", dependencies: ["MochiCore"], resources: [.process("Resources")]),
    .testTarget(name: "MochiCoreTests", dependencies: ["MochiCore"]),
    .testTarget(name: "MochiAppTests", dependencies: ["MochiApp", "MochiCore"])
])
