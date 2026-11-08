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
                "CHBcrypt",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        // OpenSSH's KDF for keys with a passphrase (bcrypt_pbkdf) in C: fast in debug builds too.
        .target(
            name: "CHBcrypt",
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        // zstd's decompression (Tools/vendor-zstd.sh: zstd 1.5.7, BSD license): Apple's
        // Compression framework has no zstd, and ClickHouse servers may send it.
        .target(
            name: "CHZstd",
            exclude: ["zstd/LICENSE"],
            cSettings: [.define("ZSTD_DISABLE_ASM"), .define("ZSTD_LEGACY_SUPPORT", to: "0"), .define("DEBUGLEVEL", to: "0"),
                        .unsafeFlags(["-O3"])]
        ),
        .target(
            name: "ClickHouseCore",
            dependencies: ["CHDecode", "CHZstd"],
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
