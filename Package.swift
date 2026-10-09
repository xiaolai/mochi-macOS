// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Mochi", platforms: [.macOS(.v14)], products: [.executable(name: "Mochi", targets: ["MochiApp"]), .executable(name:"mochi-mcp",targets:["MochiMCP"])], targets: [
    .target(name:"MochiAutomation"),
    .target(name: "MochiCore",dependencies:["MochiAutomation"]),
    .executableTarget(name:"MochiMCP",dependencies:["MochiAutomation"]),
    .executableTarget(name: "MochiApp", dependencies: ["MochiCore"], resources: [.process("Resources")],swiftSettings:[.define("MOCHI_DEVELOPMENT",.when(configuration:.debug))]),
    .testTarget(name: "MochiCoreTests", dependencies: ["MochiCore","MochiAutomation"]),
    .testTarget(name: "MochiAppTests", dependencies: ["MochiApp", "MochiCore"])
])
