// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsageTracker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CodexUsageTracker",
            path: "Sources/CodexUsageTracker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
