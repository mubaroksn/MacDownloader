// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wwwrap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wwwrap", targets: ["wwwrap"]),
        .library(name: "DownloadCore", targets: ["DownloadCore"]),
    ],
    targets: [
        // UI-free transfer engine: probing, segmentation, concurrent range transfer, disk I/O.
        .target(
            name: "DownloadCore",
            path: "Sources/DownloadCore"
        ),
        // The SwiftUI/AppKit app: queue, persistence, power management, menu bar, browser ingest.
        .executableTarget(
            name: "wwwrap",
            dependencies: ["DownloadCore"],
            path: "Sources/wwwrap",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Command-line throughput/CPU benchmark for the engine (used by CI and for tuning).
        .executableTarget(
            name: "mdl-bench",
            dependencies: ["DownloadCore"],
            path: "Sources/mdl-bench"
        ),
        .testTarget(
            name: "DownloadCoreTests",
            dependencies: ["DownloadCore"],
            path: "Tests/DownloadCoreTests"
        ),
    ]
)
