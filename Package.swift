// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mochi", platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Mochi", targets: ["MochiApp"]), .executable(name: "mochi-mcp", targets: ["MochiMCP"]),
    ],
    dependencies: [.package(url: "https://github.com/xiaolai/sayso.git", from: "0.4.0")],
    targets: [
        .target(name: "MochiKernel"),
        .target(name: "MochiAutomation", dependencies: ["MochiKernel"]),
        .target(name: "MochiCore", dependencies: ["MochiKernel"]),
        .target(
            name: "MochiProviders",
            dependencies: [
                "MochiKernel", "MochiAutomation", "MochiCore", .product(name: "CodexAuth", package: "sayso"),
                .product(name: "RealtimeConnection", package: "sayso"), .product(name: "SaidGuard", package: "sayso"),
                .product(name: "PCM16", package: "sayso"),
            ]),
        .executableTarget(name: "MochiMCP", dependencies: ["MochiAutomation"]),
        .executableTarget(
            name: "MochiApp",
            dependencies: [
                "MochiKernel", "MochiAutomation", "MochiCore", "MochiProviders",
                .product(name: "PCM16", package: "sayso"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.define("MOCHI_DEVELOPMENT", .when(configuration: .debug))]),
        .target(
            name: "MochiTestSupport", dependencies: [.product(name: "RealtimeConnection", package: "sayso")],
            path: "Tests/MochiTestSupport"),
        .testTarget(name: "MochiKernelTests", dependencies: ["MochiKernel"]),
        .testTarget(
            name: "MochiAutomationTests", dependencies: ["MochiKernel", "MochiAutomation", "MochiTestSupport"]),
        .testTarget(
            name: "MochiCoreTests",
            dependencies: ["MochiKernel", "MochiCore", "MochiTestSupport", .product(name: "PCM16", package: "sayso")]),
        .testTarget(
            name: "MochiProvidersTests",
            dependencies: [
                "MochiKernel", "MochiCore", "MochiProviders", "MochiTestSupport",
                .product(name: "CodexAuth", package: "sayso"), .product(name: "RealtimeConnection", package: "sayso"),
                .product(name: "SaidGuard", package: "sayso"), .product(name: "PCM16", package: "sayso"),
            ]),
        .testTarget(
            name: "MochiAppTests",
            dependencies: [
                "MochiKernel", "MochiAutomation", "MochiApp", "MochiCore", "MochiProviders", "MochiTestSupport",
                .product(name: "RealtimeConnection", package: "sayso"), .product(name: "PCM16", package: "sayso"),
            ]),
    ])
