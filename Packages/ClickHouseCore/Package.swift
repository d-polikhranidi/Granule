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
        .library(name: "ClickHouseSSH", targets: ["ClickHouseSSH"]),
        .executable(name: "ch-bench", targets: ["CHBench"]),
    ],
    dependencies: [
        // SSH tunnels (Apple's SSH on SwiftNIO; the core itself needs nothing).
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        // A server reached through an SSH bastion: a local port forwarded to it.
        .target(
            name: "ClickHouseSSH",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .target(
            name: "ClickHouseCore",
            dependencies: ["CHDecode"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        // The loops over every value of a result in C: fast in debug builds too.
        // Ryu (ryu/, Boost license) for floats' shortest digits.
        .target(
            name: "CHDecode",
            cSettings: [.headerSearchPath("."), .unsafeFlags(["-O3"])]
        ),
        .executableTarget(
            name: "CHBench",
            dependencies: ["ClickHouseCore"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "ClickHouseCoreTests",
            dependencies: ["ClickHouseCore", "ClickHouseSSH", "CHDecode"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ]
)
