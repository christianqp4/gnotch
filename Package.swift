// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GNotch", path: "Sources/GNotch")
    ]
)
