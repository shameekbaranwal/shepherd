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
        // Phase-1 prototype: a floating notch panel (SwiftPM-built, no Xcode)
        // to de-risk the notch window + SwiftUI queue before the fork.
        .executable(name: "herd-notch", targets: ["herd-notch"]),
    ],
    targets: [
        .target(name: "HerdBridge"),
        .executableTarget(name: "herd", dependencies: ["HerdBridge"]),
        .executableTarget(name: "herd-notch", dependencies: ["HerdBridge"]),
    ]
)
