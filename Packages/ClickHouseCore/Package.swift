// swift-tools-version: 6.2
import PackageDescription

// The viewer's core, shared by the Mac and iPad/iPhone apps: talking to a
// ClickHouse server over HTTP and reading its results, column by column. No UI
// and no table engine here.
let package = Package(
    name: "ClickHouseCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClickHouseCore", targets: ["ClickHouseCore"]),
        .executable(name: "ch-bench", targets: ["CHBench"]),
    ],
    targets: [
        .target(
            name: "ClickHouseCore",
            dependencies: ["CHDecode"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        // The loops over every value of a result in C: fast in debug builds too.
        .target(
            name: "CHDecode",
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        .executableTarget(
            name: "CHBench",
            dependencies: ["ClickHouseCore"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "ClickHouseCoreTests",
            dependencies: ["ClickHouseCore"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ]
)
