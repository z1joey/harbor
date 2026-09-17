// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "harbor-core",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HarborCore", targets: ["HarborCore"]),
        .executable(name: "harbor-tui", targets: ["harbor-tui"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    ],
    targets: [
        .target(
            name: "HarborCore",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit")
            ]
        ),
        // Terminal rendering + widgets. Kept separate from the executable so
        // the unit tests can link it without dragging in a main.swift.
        .target(
            name: "HarborTUIKit",
            dependencies: ["HarborCore"]
        ),
        .executableTarget(
            name: "harbor-tui",
            dependencies: [
                "HarborTUIKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "HarborCoreTests",
            dependencies: ["HarborCore"]
        ),
        .testTarget(
            name: "HarborTUIKitTests",
            dependencies: ["HarborTUIKit"]
        ),
    ]
)
