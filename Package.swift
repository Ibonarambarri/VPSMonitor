// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPSMonitor",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "VPSMonitor", targets: ["VPSMonitor"])],
    targets: [
        .executableTarget(
            name: "VPSMonitor",
            path: "Sources/VPSMonitor"
        ),
        .testTarget(
            name: "VPSMonitorTests",
            dependencies: ["VPSMonitor"],
            path: "Tests/VPSMonitorTests"
        )
    ]
)
