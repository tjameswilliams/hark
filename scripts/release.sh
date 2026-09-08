#!/bin/zsh
# Build, sign, notarize and package Hark for distribution. Produces:
#   dist/Hark.dmg                  evergreen first-install download (the site's button)
#   dist/updates/Hark-<v>.dmg      versioned artifact the Homebrew cask pins
# and stamps packaging/hark.rb with the version, url and sha256.
#
#   scripts/release.sh <version>                   full run (needs the notary profile)
#   scripts/release.sh <version> --skip-notarize   signed dmg only, for a local smoke test
#
# Then: website/scripts/deploy.sh uploads both dmgs to S3/CloudFront, and the
# stamped cask is copied into the tap (see docs/releasing.md).
#
# Notarization credentials live in the login keychain under a notarytool
# profile. The sibling projects share one (same Apple ID, same team), so the
# default is that profile; override with NOTARY_PROFILE. One-time setup:
#   xcrun notarytool store-credentials opencodego-notary \
#     --apple-id <your Apple ID email> --team-id 7NHJT99NX8
set -euo pipefail

SCRIPT_DIR=${0:a:h}
ROOT=${SCRIPT_DIR:h}
BUILD="$ROOT/build"
DIST="$ROOT/dist"
IDENTITY="${HARK_SIGN_IDENTITY:-Developer ID Application: Tim Williams (7NHJT99NX8)}"
PROFILE="${NOTARY_PROFILE:-opencodego-notary}"
CASK="$ROOT/packaging/hark.rb"
OUTPUTS="$ROOT/website/infra/outputs.json"

VERSION="${1:-}"
if [[ -z "$VERSION" || "$VERSION" == --* ]]; then
  echo "usage: release.sh <version> [--skip-notarize]   (e.g. release.sh 0.1.0)" >&2
  exit 2
fi
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)
SKIP_NOTARIZE=false
[[ "${2:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=true

if ! $SKIP_NOTARIZE; then
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "release: no notary credentials under profile '$PROFILE'." >&2
    echo "Run the store-credentials command in this script's header, or pass --skip-notarize." >&2
    exit 1
  fi
fi

echo "==> Building Hark $VERSION ($BUILD_NUMBER)"
HARK_VERSION="$VERSION" HARK_BUILD="$BUILD_NUMBER" HARK_SIGN_IDENTITY="$IDENTITY" \
  "$ROOT/scripts/build-app.sh"

APP="$BUILD/Hark.app"
[[ -d "$APP" ]] || { echo "release: build produced no app" >&2; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q audio-input \
  || { echo "release: audio-input entitlement missing; the mic would be blocked under the hardened runtime" >&2; exit 1; }

STAGE="$BUILD/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST/updates"
cp -R "$APP" "$STAGE/Hark.app"

if ! $SKIP_NOTARIZE; then
  echo "==> Notarizing app"
  ditto -c -k --keepParent "$STAGE/Hark.app" "$BUILD/Hark.zip"
  xcrun notarytool submit "$BUILD/Hark.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$STAGE/Hark.app"
fi

echo "==> Building dmg"
ln -sf /Applications "$STAGE/Applications"
rm -f "$BUILD/Hark.dmg"
hdiutil create -volname "Hark" -srcfolder "$STAGE" -ov -format UDZO -quiet "$BUILD/Hark.dmg"
codesign --sign "$IDENTITY" --timestamp "$BUILD/Hark.dmg"

if ! $SKIP_NOTARIZE; then
  echo "==> Notarizing dmg"
  xcrun notarytool submit "$BUILD/Hark.dmg" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$BUILD/Hark.dmg"
  echo "==> Gatekeeper assessment"
  spctl --assess --type open --context context:primary-signature -v "$BUILD/Hark.dmg"
fi

cp "$BUILD/Hark.dmg" "$DIST/Hark.dmg"
cp "$BUILD/Hark.dmg" "$DIST/updates/Hark-$VERSION.dmg"
SHA=$(shasum -a 256 "$DIST/updates/Hark-$VERSION.dmg" | cut -d' ' -f1)
# What the cask's livecheck reads; deploy.sh uploads it with the dmgs.
printf '%s\n' "$VERSION" > "$DIST/updates/latest-version.txt"

# Stamp the cask. The url is the site's origin from the last deploy (the
# CloudFront URL until a domain exists); it stays valid after a domain is
# added, so nothing already installed is disturbed.
SITE_URL=""
if [[ -f "$OUTPUTS" ]]; then
  SITE_URL=$(node -p "require('$OUTPUTS').HarkWebsite.SiteUrl")
fi
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
if [[ -n "$SITE_URL" ]]; then
  sed -i '' -E "s#^  url \"[^\"]*/downloads/#  url \"$SITE_URL/downloads/#" "$CASK"
  sed -i '' -E "s#^  homepage \".*\"#  homepage \"$SITE_URL/\"#" "$CASK"
else
  echo "    (no website/infra/outputs.json yet: cask url left as-is; deploy the site, then re-stamp)"
fi

echo
echo "==> Done"
echo "    $DIST/Hark.dmg"
echo "    $DIST/updates/Hark-$VERSION.dmg  sha256 $SHA"
echo "    $CASK stamped"
echo "    Next: website/scripts/deploy.sh, then copy packaging/hark.rb to the tap (docs/releasing.md)"
