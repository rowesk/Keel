// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Keel",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Keel", targets: ["KeelApp"]),
    ],
    targets: [
        .target(name: "KeelFoundation"),
        .target(
            name: "KeelStore",
            dependencies: ["KeelFoundation"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "KeelCoordinator",
            dependencies: ["KeelFoundation", "KeelStore"]
        ),
        .target(
            name: "KeelWeb",
            dependencies: ["KeelCoordinator", "KeelFoundation", "KeelStore", "KeelUI"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        ),
        .target(
            name: "KeelUI",
            dependencies: ["KeelFoundation"],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("SwiftUI")]
        ),
        .executableTarget(
            name: "KeelApp",
            dependencies: ["KeelCoordinator", "KeelFoundation", "KeelStore", "KeelUI", "KeelWeb"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "KeelFoundationTests",
            dependencies: ["KeelFoundation"]
        ),
        .testTarget(
            name: "KeelStoreTests",
            dependencies: ["KeelFoundation", "KeelStore"]
        ),
        .testTarget(
            name: "KeelCoordinatorTests",
            dependencies: ["KeelCoordinator", "KeelFoundation", "KeelStore"]
        ),
        .testTarget(
            name: "KeelWebTests",
            dependencies: ["KeelWeb", "KeelCoordinator", "KeelStore"]
        ),
        .testTarget(
            name: "KeelUITests",
            dependencies: ["KeelUI"],
            // The snapshot baselines are read from disk by path, not from a
            // bundle, so SwiftPM should leave them alone.
            exclude: ["__Snapshots__"]
        ),
        .testTarget(
            name: "KeelAppTests",
            dependencies: ["KeelApp", "KeelStore"]
        ),
    ]
)
