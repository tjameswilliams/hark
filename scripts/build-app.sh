#!/usr/bin/env bash
# Builds the Hark menu-bar app end to end:
#   Rust core -> UniFFI Swift bindings -> SwiftPM release build -> Hark.app
# Run from anywhere; everything is relative to the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# Match the SwiftPM deployment target (macOS 15) for the crate's objects.
# Note: ld may still warn about Rust's *prebuilt std* objects if the Rust
# toolchain built libstd against a newer SDK — harmless (same as the spike).
export MACOSX_DEPLOYMENT_TARGET=15.0

echo "==> [1/5] cargo build --release -p hark-core"
cargo build --release -p hark-core

LIB="target/release/libhark_core.a"
[ -f "$LIB" ] || { echo "error: $LIB not found"; exit 1; }

echo "==> [2/5] uniffi-bindgen-swift: Swift sources + FFI header + modulemap"
GEN="apps/Hark/.uniffi-generated"
rm -rf "$GEN"
mkdir -p "$GEN"
BINDGEN=(cargo run --release --quiet -p hark-core --features bindgen --bin uniffi-bindgen-swift --)
"${BINDGEN[@]}" "$LIB" "$GEN" --swift-sources
"${BINDGEN[@]}" "$LIB" "$GEN" --headers
"${BINDGEN[@]}" "$LIB" "$GEN" --modulemap \
    --module-name hark_coreFFI --modulemap-filename module.modulemap

# Wire generated output into the SwiftPM layout (mirrors the UniFFI spike):
#   - generated .swift files compile into the executable target
#   - header + module.modulemap form the systemLibrary C module
mkdir -p apps/Hark/Sources/Hark/Generated apps/Hark/Sources/hark_coreFFI
rm -f apps/Hark/Sources/Hark/Generated/*.swift
cp "$GEN"/*.swift apps/Hark/Sources/Hark/Generated/
cp "$GEN"/*.h apps/Hark/Sources/hark_coreFFI/
cp "$GEN"/module.modulemap apps/Hark/Sources/hark_coreFFI/module.modulemap
rm -rf "$GEN"

echo "==> [3/5] swift build -c release (apps/Hark)"
(cd apps/Hark && swift build -c release)

echo "==> [4/5] assembling build/Hark.app"
APP="build/Hark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp apps/Hark/.build/release/Hark "$APP/Contents/MacOS/Hark"
cp apps/Hark/Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Prefer a real signing identity: TCC keys grants to the signing identity, so
# a Developer ID-signed app keeps Accessibility/Microphone across rebuilds
# (ad-hoc signatures change per build and reset TCC — and were observed to
# leave the Accessibility grant unhonored for Finder-launched instances on
# macOS 26). Override with HARK_SIGN_IDENTITY; falls back to ad-hoc.
IDENTITY="${HARK_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 "Developer ID Application" \
        | sed -E 's/.*"(.*)".*/\1/' || true)
fi
if [ -n "$IDENTITY" ]; then
    echo "==> [5/5] codesign ($IDENTITY)"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> [5/5] codesign (ad-hoc — no Developer ID identity found)"
    codesign --force --deep -s - "$APP"
fi

echo ""
echo "Build complete: $REPO_ROOT/$APP"
echo ""
echo "Run it with:"
echo "  open build/Hark.app"
echo ""
echo "First launch: grant Accessibility + Microphone to Hark in"
echo "System Settings > Privacy & Security, then hold right ⌘ and speak."
if [ -z "$IDENTITY" ]; then
    echo ""
    echo "NOTE: ad-hoc signed — TCC grants reset whenever the binary changes."
fi
echo ""
echo "Logs: ~/Library/Logs/Hark/hark.log"
