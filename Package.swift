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
        // Portable App services: the catalog, grouping, suggestion and fixture services without
        // the UIKit-only views. Excluded files compile only inside the AFITC app target.
        .target(
            name: "AFITCApp",
            dependencies: ["AFITCCore", "AFITCRuntime"],
            path: "App",
            exclude: [
                "AFITCApp.swift",
                "Info.plist",
                "RootView.swift",
                "PeopleView.swift",
                "PersonDetailView.swift",
                "VerifyView.swift",
                "FaceGroupView.swift",
                "SearchView.swift",
                "LibraryView.swift",
                "SettingsView.swift",
                "StatusView.swift",
                "PhotoViewer.swift",
                "DesignTokens.swift",
                "Components",
                "Services/CatalogPackagePicker.swift"
            ]
        ),
        .testTarget(
            name: "AFITCAppTests",
            dependencies: ["AFITCApp", "AFITCCore"],
            path: "Tests/AFITCAppTests"
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
