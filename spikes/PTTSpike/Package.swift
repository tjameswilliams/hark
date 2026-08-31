// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PTTSpike",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ptt",
            path: "Sources/ptt"
        )
    ]
)
