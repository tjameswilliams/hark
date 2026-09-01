#!/usr/bin/env bash
# Post-processes the hark-core Rust staticlib into an FFI-only archive:
#   target/release/libhark_core.a  ->  target/release/libhark_core_ffi.a
#
# Why: the raw staticlib bundles the whole Rust std, whose global
# `_rust_eh_personality` collides with the copy inside FluidAudio's prebuilt
# NemoTextProcessing xcframework (libtext_processing_rs.a bundles its own
# Rust std). The release linker demotes the duplicate to a warning but the
# debug link hard-fails. Fix: `ld -r` the archive into one relocatable
# object with ONLY the UniFFI FFI surface exported (`_uniffi_hark_core_*`,
# `_ffi_hark_core_*`); every Rust-internal symbol — including
# `_rust_eh_personality` — becomes local (and `-x` strips the local names),
# so the two Rust stds can no longer collide. No dylibs introduced, so the
# notarization story is unchanged.
#
# Note `-all_load` is NOT usable here: the archive contains duplicate
# member-level symbols of its own (onnx protobuf objects appear twice via
# the ort build). Instead the link is seeded with `-u <sym>` for each FFI
# symbol, so ld pulls exactly the members (transitively) needed.
set -euo pipefail
cd "$(dirname "$0")/.."

LIB="target/release/libhark_core.a"
OUT="target/release/libhark_core_ffi.a"
[ -f "$LIB" ] || { echo "error: $LIB not found (run: cargo build --release -p hark-core)"; exit 1; }

ARCH="$(uname -m)"          # arm64 on Apple Silicon, x86_64 on Intel
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The exported surface: everything the UniFFI bindgen header declares. The
# symbol names are recovered from the archive itself (same set the header
# declares, `_`-prefixed) so this script has no dependency on bindgen output.
nm -gUj "$LIB" 2>/dev/null | grep -E '^_(uniffi|ffi)_hark_core' | sort -u > "$WORK/syms.txt"
COUNT="$(wc -l < "$WORK/syms.txt" | tr -d ' ')"
[ "$COUNT" -gt 0 ] || { echo "error: no uniffi/ffi hark_core symbols found in $LIB"; exit 1; }

printf '_uniffi_hark_core_*\n_ffi_hark_core_*\n' > "$WORK/exports.txt"

UFLAGS=()
while read -r sym; do UFLAGS+=(-u "$sym"); done < "$WORK/syms.txt"

# Stamp the platform so the final link doesn't warn "no platform load
# command found" (min version matches MACOSX_DEPLOYMENT_TARGET in
# build-app.sh; sdk version from the active toolchain).
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 15.0)"
ld -r -arch "$ARCH" -x \
    -platform_version macos "${MACOSX_DEPLOYMENT_TARGET:-15.0}" "$SDK_VERSION" \
    -exported_symbols_list "$WORK/exports.txt" \
    "${UFLAGS[@]}" \
    "$LIB" -o "$WORK/hark_core_ffi.o" 2> "$WORK/ld-stderr.txt" || {
        cat "$WORK/ld-stderr.txt" >&2
        exit 1
    }
# Surface real warnings; the kleidiai asm alignment + vendored-asm dwarf
# notes are known-noisy and harmless.
grep -vE 'not 4-byte aligned|can.t parse dwarf|platform not specified' \
    "$WORK/ld-stderr.txt" >&2 || true

# Sanity: the combined object must export exactly the FFI surface and no
# stray Rust-std globals.
if nm -gU "$WORK/hark_core_ffi.o" | grep -qv -E '_(uniffi|ffi)_hark_core'; then
    echo "error: unexpected exported symbols remain in the localized object:" >&2
    nm -gU "$WORK/hark_core_ffi.o" | grep -v -E '_(uniffi|ffi)_hark_core' | head >&2
    exit 1
fi

libtool -static -o "$OUT" "$WORK/hark_core_ffi.o" 2>/dev/null \
    || ar crs "$OUT" "$WORK/hark_core_ffi.o"

echo "localized: $OUT ($COUNT exported FFI symbols)"
