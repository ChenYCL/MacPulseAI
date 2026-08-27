// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacPulse",
            path: "Sources/MacPulse"
        ),
        .testTarget(
            name: "MacPulseTests",
            dependencies: ["MacPulse"],
            path: "Tests/MacPulseTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
