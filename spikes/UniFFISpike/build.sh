#!/usr/bin/env bash
# Spike #4: build the Rust engine, generate UniFFI Swift bindings, build the
# Swift executable that links the Rust static lib.
set -euo pipefail
cd "$(dirname "$0")"

# Match the SwiftPM deployment target (macOS 15) for our crate's objects.
# Note: ld may still warn about Rust's *prebuilt std* objects if your Rust
# toolchain built libstd against a newer SDK (e.g. Homebrew Rust on macOS 26).
# Those warnings are harmless for this spike.
export MACOSX_DEPLOYMENT_TARGET=15.0

echo "==> [1/3] cargo build --release (engine)"
(cd engine && cargo build --release)

LIB=engine/target/release/libhark_engine_spike.a

echo "==> [2/3] uniffi-bindgen-swift: Swift sources + FFI header + modulemap"
GEN=generated
rm -rf "$GEN"
mkdir -p "$GEN"
(cd engine && cargo run --release --quiet --bin uniffi-bindgen-swift -- \
    "target/release/libhark_engine_spike.a" "../$GEN" --swift-sources)
(cd engine && cargo run --release --quiet --bin uniffi-bindgen-swift -- \
    "target/release/libhark_engine_spike.a" "../$GEN" --headers)
(cd engine && cargo run --release --quiet --bin uniffi-bindgen-swift -- \
    "target/release/libhark_engine_spike.a" "../$GEN" --modulemap \
    --module-name hark_engine_spikeFFI --modulemap-filename module.modulemap)

# Wire generated output into the SwiftPM layout:
#   - generated .swift files compile into the executable target
#   - header + module.modulemap form the systemLibrary C module
mkdir -p app/Sources/interop app/Sources/hark_engine_spikeFFI
rm -f app/Sources/interop/hark_engine_spike*.swift
cp "$GEN"/*.swift app/Sources/interop/
cp "$GEN"/*.h app/Sources/hark_engine_spikeFFI/
cp "$GEN"/module.modulemap app/Sources/hark_engine_spikeFFI/module.modulemap

echo "==> [3/3] swift build (app)"
(cd app && swift build -c release)

echo ""
echo "Build complete. Run:"
echo "  ./app/.build/release/interop"
