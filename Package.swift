// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "darkroom",
    // The menu bar app uses SwiftUI-era AppKit APIs (NSSwitch, MainActor
    // tasks), so the whole package targets macOS 13.
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "DarkroomKit"
        ),
        .executableTarget(
            name: "darkroom",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "DarkroomKit",
            ]
        ),
        .executableTarget(
            name: "darkroomd",
            dependencies: ["DarkroomKit"]
        ),
        // Menu bar app with the intensity slider. Built as a plain executable
        // and wrapped into Darkroom.app by `make app`.
        .executableTarget(
            name: "darkroom-gui",
            dependencies: ["DarkroomKit"]
        ),
        .testTarget(
            name: "darkroom-tests",
            dependencies: ["DarkroomKit"]
        ),
    ]
)
