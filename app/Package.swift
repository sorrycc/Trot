// swift-tools-version: 6.2
import PackageDescription

// Build through scripts/bundle.sh, which assembles build/Trot.app.
// `swift test --package-path app` runs the unit tests.
let package = Package(
    name: "Trot",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Trot", path: "Sources/Trot"),
        .testTarget(name: "TrotTests", dependencies: ["Trot"], path: "Tests/TrotTests"),
    ]
)
