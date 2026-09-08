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

echo "==> [1/6] cargo build --release -p hark-core -p hark-mcp"
cargo build --release -p hark-core -p hark-mcp

LIB="target/release/libhark_core.a"
[ -f "$LIB" ] || { echo "error: $LIB not found"; exit 1; }
MCP_BIN="target/release/hark-mcp"
[ -f "$MCP_BIN" ] || { echo "error: $MCP_BIN not found"; exit 1; }

# Localize the staticlib to its FFI surface (libhark_core_ffi.a) — this is
# what Package.swift links. Fixes the duplicate `_rust_eh_personality`
# against FluidAudio's prebuilt NemoTextProcessing xcframework (which
# bundles its own Rust std); see the script header for details.
echo "==> [2/6] localize hark-core staticlib (FFI-only exports)"
scripts/localize-hark-core-ffi.sh

echo "==> [3/6] uniffi-bindgen-swift: Swift sources + FFI header + modulemap"
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

echo "==> [4/6] swift build -c release (apps/Hark)"
(cd apps/Hark && swift build -c release)

echo "==> [5/6] assembling build/Hark.app"
APP="build/Hark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp apps/Hark/.build/release/Hark "$APP/Contents/MacOS/Hark"
# Bundle the MCP server next to the main executable: the settings screen
# invokes it via Bundle.main.executableURL
#   .deletingLastPathComponent().appendingPathComponent("hark-mcp")
# i.e. exactly Contents/MacOS/hark-mcp.
cp "$MCP_BIN" "$APP/Contents/MacOS/hark-mcp"
cp apps/Hark/Support/Info.plist "$APP/Contents/Info.plist"
cp apps/Hark/Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp apps/Hark/Support/MenuBarIcon.png apps/Hark/Support/MenuBarIcon@2x.png "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Release builds (scripts/release.sh) stamp the version before signing;
# the checked-in Info.plist keeps the development values.
if [ -n "${HARK_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $HARK_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${HARK_BUILD:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $HARK_BUILD" "$APP/Contents/Info.plist"
fi

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
    echo "==> [6/6] codesign ($IDENTITY)"
    # Hardened runtime + timestamp are what notarization requires; the
    # entitlements file re-allows the microphone under the hardened runtime.
    SIGN=(--sign "$IDENTITY" --options runtime --timestamp
          --entitlements apps/Hark/Support/Hark.entitlements)
else
    echo "==> [6/6] codesign (ad-hoc — no Developer ID identity found)"
    SIGN=(-s -)
fi
# Sign the nested hark-mcp binary explicitly first (auxiliary executables in
# Contents/MacOS are NOT reliably covered by --deep, which only walks nested
# code in standard locations), then the app bundle.
codesign --force "${SIGN[@]}" "$APP/Contents/MacOS/hark-mcp"
codesign --force --deep "${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$APP/Contents/MacOS/hark-mcp"

echo ""
echo "Build complete: $REPO_ROOT/$APP"
echo "MCP server:     $REPO_ROOT/$APP/Contents/MacOS/hark-mcp"
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
