// swift-tools-version:6.0
import PackageDescription

// Spike-grade linking: we point straight at the cargo release output.
// Production would ship an XCFramework instead (see README).
let engineLib = "../engine/target/release/libhark_engine_spike.a"

let package = Package(
    name: "interop",
    platforms: [.macOS(.v15)],
    targets: [
        // C module for the UniFFI-generated FFI header (module.modulemap lives here).
        .systemLibrary(
            name: "hark_engine_spikeFFI",
            path: "Sources/hark_engine_spikeFFI"
        ),
        .executableTarget(
            name: "interop",
            dependencies: ["hark_engine_spikeFFI"],
            path: "Sources/interop",
            linkerSettings: [
                // Hand the static archive straight to the linker so we never
                // pick up the cdylib by accident. Path is relative to the
                // `swift build` working directory (this package dir).
                .unsafeFlags(["-Xlinker", engineLib])
            ]
        ),
    ]
)
