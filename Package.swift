// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TideIsland",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TideIslandCore", targets: ["TideIslandCore"]),
        .executable(name: "tide-island-bridge", targets: ["TideIslandBridge"]),
    ],
    targets: [
        .target(name: "TideIslandCore"),
        .executableTarget(name: "TideIslandBridge", dependencies: ["TideIslandCore"]),
        .testTarget(name: "TideIslandCoreTests", dependencies: ["TideIslandCore"]),
    ]
)
