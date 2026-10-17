// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacDownloader",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacDownloader", targets: ["MacDownloader"]),
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
            name: "MacDownloader",
            dependencies: ["DownloadCore"],
            path: "Sources/MacDownloader",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "DownloadCoreTests",
            dependencies: ["DownloadCore"],
            path: "Tests/DownloadCoreTests"
        ),
    ]
)
