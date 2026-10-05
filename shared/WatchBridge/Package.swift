// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchBridge",
    // macOS so the encoding tests run from the command line; WatchConnectivity
    // itself exists on neither macOS nor, usefully, the simulator.
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "WatchBridge", targets: ["WatchBridge"])
    ],
    targets: [
        .target(name: "WatchBridge"),
        .testTarget(name: "WatchBridgeTests", dependencies: ["WatchBridge"]),
    ]
)
