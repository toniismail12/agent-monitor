// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AgentMonitorKit",
            path: "Sources/AgentMonitorKit"
        ),
        .executableTarget(
            name: "AgentMonitor",
            dependencies: ["AgentMonitorKit"],
            path: "Sources/AgentMonitor"
        ),
        .executableTarget(
            name: "AgentMonitorChecks",
            dependencies: ["AgentMonitorKit"],
            path: "Sources/AgentMonitorChecks"
        )
    ]
)
