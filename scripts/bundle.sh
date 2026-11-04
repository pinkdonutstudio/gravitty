#!/bin/bash
# Builds build/Gravitty.app from the Swift package (arm64 release) and signs it.
# GRAVITTY_SIGN_ID picks the signing identity (name or hash from `security find-identity -v -p codesigning`);
# default is ad-hoc ("-"), which runs on this Mac but not as a distributable build.
# GRAVITTY_NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile name) also notarizes, staples and zips it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)/Gravitty

APP=build/Gravitty.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Gravitty"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.pinkdonutstudio.gravitty</string>
  <key>CFBundleName</key><string>Gravitty</string>
  <key>CFBundleExecutable</key><string>Gravitty</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --options runtime --sign "${GRAVITTY_SIGN_ID:--}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

if [ -n "${GRAVITTY_NOTARY_PROFILE:-}" ]; then
  ditto -c -k --keepParent "$APP" build/Gravitty.zip
  xcrun notarytool submit build/Gravitty.zip --keychain-profile "$GRAVITTY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" build/Gravitty.zip # re-zip with the ticket stapled in
  spctl --assess --type execute -v "$APP"           # what Gatekeeper will say on another Mac
fi
echo "built $APP"
