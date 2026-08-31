// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioTapSpike",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "audiotap",
            path: "Sources/audiotap"
        )
    ]
)
