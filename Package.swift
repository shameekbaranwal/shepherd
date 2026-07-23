// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "shepherd",
    platforms: [.macOS(.v14)],
    products: [
        // The portable herdr-socket bridge: connection, models, live herd state.
        .library(name: "HerdBridge", targets: ["HerdBridge"]),
        // Phase-0 spike: headless live table of the herd in the terminal.
        .executable(name: "herd", targets: ["herd"]),
    ],
    targets: [
        .target(name: "HerdBridge"),
        .executableTarget(name: "herd", dependencies: ["HerdBridge"]),
    ]
)
