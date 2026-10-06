// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingProcSpike",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "meetingproc",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        // Speaker-identity spike: dumps per-speaker voiceprints per recording
        // so cross-meeting match distances can be measured offline.
        .executableTarget(
            name: "voiceprint",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
    ]
)
