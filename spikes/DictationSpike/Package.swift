// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictationSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "dictate",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/dictate"
        )
    ]
)
