#!/bin/bash
# Builds a release: the signed (and notarized) app, a DMG with an Applications link, and the Sparkle appcast.
# Usage: GRAVITTY_SIGN_ID=<Developer ID Application identity> GRAVITTY_NOTARY_PROFILE=<notarytool profile> \
#          scripts/release.sh <version> <build>      e.g. 0.1.0 1
# <build> is the number Sparkle compares, so it must be higher than the last release. Output goes to build/release
# (OUT_DIR overrides it): Gravitty-<version>.dmg and appcast.xml, the two files to upload to the GitHub release.
# Without GRAVITTY_NOTARY_PROFILE it still builds everything but skips notarization, which is enough for a test run.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?version, e.g. 0.1.0}"
BUILD="${2:?build number, higher than the last release}"
SIGN="${GRAVITTY_SIGN_ID:?set GRAVITTY_SIGN_ID to a Developer ID Application identity}"
OUT="${OUT_DIR:-build/release}"

rm -rf "$OUT"
mkdir -p "$OUT"
# bundle.sh builds, signs, and (with a notary profile) notarizes and staples the app
GRAVITTY_VERSION="$VERSION" GRAVITTY_BUILD="$BUILD" APP_DIR="$OUT" scripts/bundle.sh

STAGE=$(mktemp -d)
ditto "$OUT/Gravitty.app" "$STAGE/Gravitty.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Gravitty-$VERSION.dmg"
hdiutil create -volname Gravitty -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$SIGN" "$DMG"
if [ -n "${GRAVITTY_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$GRAVITTY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

# Sparkle only needs the newest release in the feed, so the appcast is made from this DMG alone.
FEED=$(mktemp -d)
cp "$DMG" "$FEED/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/pinkdonutstudio/gravitty/releases/download/v$VERSION/" "$FEED"
cp "$FEED/appcast.xml" "$OUT/appcast.xml"
rm -rf "$FEED"

echo
echo "release $VERSION (build $BUILD) is in $OUT:"
ls -lh "$DMG" "$OUT/appcast.xml"
echo "publish: gh release create v$VERSION \"$DMG\" \"$OUT/appcast.xml\" --title \"Gravitty $VERSION\""
