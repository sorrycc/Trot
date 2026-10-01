// swift-tools-version: 6.2
import PackageDescription

// Build through scripts/bundle.sh, which assembles build/Trot.app.
let package = Package(
    name: "Trot",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Trot", path: "Sources/Trot")
    ]
)
