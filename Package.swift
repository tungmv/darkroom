// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "darkroom",
    platforms: [.macOS(.v10_13)],
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
        .testTarget(
            name: "darkroom-tests",
            dependencies: ["DarkroomKit"]
        ),
    ]
)
