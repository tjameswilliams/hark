# Spike #4 — UniFFI: Rust ↔ Swift in-process boundary

Proves the in-process FFI boundary planned for Hark: a Rust engine library
exposed to Swift via **UniFFI 0.32.0** (proc-macro mode, no UDL), where

1. Swift pushes PCM audio buffers (`Vec<i16>`) into a Rust `EngineSession`,
2. Rust delivers transcript-like events back to Swift through a
   foreign-implemented callback trait (`#[uniffi::export(with_foreign)]`), and
3. per-buffer FFI overhead is measured and shown to be negligible.

## Layout

```
engine/   Rust crate `hark-engine-spike` (lib + cdylib + staticlib)
          - EngineSession (uniffi object, Mutex interior mutability)
          - push_buffer(Vec<i16>) -> emits a fake TranscriptEvent per 0.5 s
          - TranscriptListener callback trait implemented in Swift
          - finish() -> EngineStats record
          - src/bin/uniffi-bindgen-swift.rs -> uniffi::uniffi_bindgen_swift()
app/      SwiftPM executable `interop` (macOS 15+)
          - Sources/interop/            main.swift + generated hark_engine_spike.swift
          - Sources/hark_engine_spikeFFI/  generated FFI header + module.modulemap
            (systemLibrary target so the generated Swift can import the C module)
build.sh  cargo build -> uniffi-bindgen-swift -> swift build
```

## Run

```sh
./build.sh
./app/.build/release/interop
```

`build.sh`:
1. `cargo build --release` in `engine/` (builds `libhark_engine_spike.a`),
2. runs the crate's `uniffi-bindgen-swift` bin in library mode against the
   `.a` three times (`--swift-sources`, `--headers`, `--modulemap
   --module-name hark_engine_spikeFFI`) into `generated/`, then copies the
   output into the SwiftPM layout,
3. `swift build -c release`, linking the static archive directly via
   `linkerSettings: [.unsafeFlags(["-Xlinker", "../engine/target/release/libhark_engine_spike.a"])]`
   (passing the archive as a linker input avoids accidentally picking the cdylib).

## Measured (M-series Mac, macOS 26, release builds)

The Swift main pushes 30 s of synthetic 16 kHz sine PCM in 10 ms buffers
(160 samples × 3000 calls), receives events via the callback, then prints
stats from `finish()`:

```
Events received via callback: 60 (expected 60)
Rust-side stats: buffers=3000 samples=480000 pushTime=0.86 ms

FFI throughput:
  total FFI push calls:        3000
  wall time for all pushes:    4.8–7.2 ms
  mean per-push (Swift side):  1.6–2.4 us
  mean per-push (Rust side):   0.26–0.40 us

PASS: mean per-push 1.75 us < 100 us budget
```

~2 µs per 10 ms buffer ≈ 0.02% of real-time — FFI overhead is a non-issue
for streaming audio at this granularity. The Swift-side mean includes the
`Vec<i16>` copy across the boundary and (every 50th call) the callback hop
back into Swift; the Rust-side mean is time inside `push_buffer` only.

## Notes / gotchas hit

- `.macOS(.v15)` in `platforms` requires `// swift-tools-version:6.0`.
- The generated modulemap defaults to module name `hark_engine_spike`, but the
  generated Swift does `import hark_engine_spikeFFI` — pass
  `--module-name hark_engine_spikeFFI` (and rename to `module.modulemap` for
  the systemLibrary target).
- Swift 6 strict concurrency: the generated `TranscriptListener` protocol is
  `Sendable` (Rust trait is `Send + Sync`), so a listener with mutable state
  needs `@unchecked Sendable` (or real synchronization).
- Rust callbacks into Swift happen synchronously on the pushing thread; the
  engine drops its Mutex before invoking the listener to avoid re-entrancy
  deadlocks.
- ld warns that Homebrew Rust's prebuilt libstd objects target macOS 26 while
  we link for 15.0 — harmless here.

## What production packaging would add

- **XCFramework**: bundle the static lib + headers + modulemap per-platform
  (`uniffi-bindgen-swift --xcframework --modulemap`), instead of `-Xlinker`
  paths into cargo's target dir.
- **cargo-swift** or a small build plugin to automate the
  cargo → bindgen → SPM pipeline, universal (arm64 + x86_64) `lipo` builds.
- Pinned `MACOSX_DEPLOYMENT_TARGET` via rustup toolchain (not Homebrew) so
  libstd matches the app's deployment target.
- Async callbacks / a dedicated engine thread rather than synchronous
  callback delivery on the audio-push thread.
