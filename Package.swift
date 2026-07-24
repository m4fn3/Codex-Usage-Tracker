// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsageTracker",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure Foundation logic (data model + reader). No AppKit, so it can be
        // unit-tested off the main app.
        .target(
            name: "CodexUsageCore",
            path: "Sources/CodexUsageCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CodexUsageTracker",
            dependencies: ["CodexUsageCore"],
            path: "Sources/CodexUsageTracker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CodexUsageCoreTests",
            dependencies: ["CodexUsageCore"],
            path: "Tests/CodexUsageCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
