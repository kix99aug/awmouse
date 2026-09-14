// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MotionInput",
    // macOS is listed only so the filter's tests can run from the command line;
    // CMMotionManager itself exists on neither macOS nor the simulator.
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "MotionInput", targets: ["MotionInput"])
    ],
    targets: [
        .target(name: "MotionInput"),
        .testTarget(name: "MotionInputTests", dependencies: ["MotionInput"]),
    ]
)
