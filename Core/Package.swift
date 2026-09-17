// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "harbor-core",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HarborCore", targets: ["HarborCore"]),
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
        .testTarget(
            name: "HarborCoreTests",
            dependencies: ["HarborCore"]
        ),
    ]
)
