// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DP32Export",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DP32Core", targets: ["DP32Core"]),
        .executable(name: "dp32export", targets: ["dp32export"]),
        .executable(name: "DP32ExportApp", targets: ["DP32ExportApp"]),
    ],
    targets: [
        .target(name: "DP32Core"),
        .executableTarget(name: "dp32export", dependencies: ["DP32Core"]),
        .executableTarget(name: "DP32ExportApp", dependencies: ["DP32Core"]),
        .testTarget(name: "DP32CoreTests", dependencies: ["DP32Core"]),
    ]
)
