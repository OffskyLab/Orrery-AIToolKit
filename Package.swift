// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIToolKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AIToolKit", targets: ["AIToolKit"]),
    ],
    targets: [
        .target(name: "AIToolKit", path: "Sources/AIToolKit"),
        .testTarget(
            name: "AIToolKitTests",
            dependencies: ["AIToolKit"],
            path: "Tests/AIToolKitTests"
        ),
    ]
)
