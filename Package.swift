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
        ),
        .library(
            name: "AFITCRuntime",
            type: .dynamic,
            targets: ["AFITCRuntime"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2")
    ],
    targets: [
        .target(
            name: "AFITCCore",
            dependencies: [],
            path: "Sources/AFITCCore"
        ),
        .target(
            name: "AFITCRuntime",
            dependencies: [
                "AFITCCore",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            path: "Sources/AFITCRuntime"
        ),
        .testTarget(
            name: "AFITCCoreTests",
            dependencies: [
                "AFITCCore",
                "AFITCRuntime",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager",
                         condition: .when(platforms: [.macOS]))
            ],
            path: "Tests/AFITCCoreTests"
        )
    ]
)
