// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeepWorkTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DeepWorkTracker", path: "Sources/DeepWorkTracker")
    ]
)
