// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokenwatch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "tw", targets: ["tw"]),
        .library(name: "UsageUI", targets: ["UsageUI"]),
        .executable(name: "Tokenwatch", targets: ["Tokenwatch"]),
    ],
    targets: [
        // All collection, storage, accounting, quota and analytics logic. It has no UI dependency,
        // so the menu bar app, the command line tool and the tests all share exactly the same code.
        .target(name: "UsageCore", dependencies: ["CZstd"]),
        // The decompression half of Zstandard, vendored because Codex compresses its older session files and
        // macOS has no usable libzstd. See Sources/CZstd/README.md for provenance and license.
        .target(
            name: "CZstd",
            exclude: ["README.md", "LICENSE"],
            publicHeadersPath: "include",
            cSettings: [
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                .define("ZSTD_MULTITHREAD", to: "0"),
            ]),
        // The SwiftUI views and the observable model behind them. Kept out of the executable so that
        // they can be unit tested and rendered headlessly.
        .target(name: "UsageUI", dependencies: ["UsageCore"]),
        .executableTarget(name: "Tokenwatch", dependencies: ["UsageUI"]),
        // Command line front end used for headless imports, verification and performance runs.
        .executableTarget(name: "tw", dependencies: ["UsageCore"]),
        // Tiny helper that Claude Code runs as its status line command. It deliberately avoids
        // depending on UsageCore so that its start-up cost stays minimal.
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "UsageUITests", dependencies: ["UsageUI", "UsageCore"]),
    ]
)
