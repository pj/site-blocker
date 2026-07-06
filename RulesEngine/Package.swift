// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RulesEngine",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "RulesEngine", targets: ["RulesEngine"]),
    ],
    targets: [
        .target(name: "RulesEngine"),
        .testTarget(name: "RulesEngineTests", dependencies: ["RulesEngine"]),
    ]
)
