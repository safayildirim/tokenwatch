// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageMonitor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .library(name: "UsageUI", targets: ["UsageUI"]),
        .executable(name: "ClaudeUsageMonitor", targets: ["ClaudeUsageMonitor"]),
        .executable(name: "ccu", targets: ["ccu"]),
        .executable(name: "ccu-statusline", targets: ["ccu-statusline"]),
    ],
    targets: [
        // All collection, storage, accounting, quota and analytics logic. It has no UI dependency,
        // so the menu bar app, the command line tool and the tests all share exactly the same code.
        .target(name: "UsageCore"),
        // The SwiftUI views and the observable model behind them. Kept out of the executable so that
        // they can be unit tested and rendered headlessly.
        .target(name: "UsageUI", dependencies: ["UsageCore"]),
        .executableTarget(name: "ClaudeUsageMonitor", dependencies: ["UsageUI"]),
        // Command line front end used for headless imports, verification and performance runs.
        .executableTarget(name: "ccu", dependencies: ["UsageCore"]),
        // Tiny helper that Claude Code runs as its status line command. It deliberately avoids
        // depending on UsageCore so that its start-up cost stays minimal.
        .executableTarget(name: "ccu-statusline"),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore", "ccu-statusline"]),
        .testTarget(name: "UsageUITests", dependencies: ["UsageUI", "UsageCore"]),
    ]
)
