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
        .executableTarget(
            name: "AIToolKitTestPlugin",
            dependencies: ["AIToolKit"],
            path: "Sources/AIToolKitTestPlugin"
        ),
        .testTarget(
            name: "AIToolKitTests",
            dependencies: ["AIToolKit", "AIToolKitTestPlugin"],
            path: "Tests/AIToolKitTests"
        ),
    ],
    // Stated rather than inherited. Tools-version 6.0 already defaults to this,
    // but a package whose registry relies on the compiler verifying its
    // Sendability should say so where a consumer reads the manifest.
    swiftLanguageModes: [.v6]
)
