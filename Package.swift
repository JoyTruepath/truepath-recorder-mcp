// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "truepath-mcp",
    platforms: [.macOS(.v13)],
    targets: [
        // Foundation-only MCP stdio server. No external dependencies.
        .executableTarget(name: "truepath-mcp", path: "Sources/truepath-mcp")
    ]
)
