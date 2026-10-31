// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TorpetEl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TorpetEl", path: "Sources/TorpetEl"),
    ],
    swiftLanguageModes: [.v5]
)
