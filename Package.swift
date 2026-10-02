// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AFITCCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AFITCCore",
            targets: ["AFITCCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AFITCCore",
            dependencies: [],
            path: "Sources/AFITCCore"
        ),
        .testTarget(
            name: "AFITCCoreTests",
            dependencies: ["AFITCCore"],
            path: "Tests/AFITCCoreTests"
        )
    ]
)
