// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonitorClaude",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MonitorClaude",
            path: "Sources/MonitorClaude",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MonitorClaudeTests",
            dependencies: ["MonitorClaude"],
            path: "Tests/MonitorClaudeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
