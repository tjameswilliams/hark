// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicProbe",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "micprobe",
            path: "Sources/micprobe"
        )
    ]
)
