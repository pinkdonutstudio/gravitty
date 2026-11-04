#!/bin/bash
# Builds build/Gravitty.app from the Swift package (arm64 release) and signs it.
# GRAVITTY_SIGN_ID picks the signing identity (name or hash from `security find-identity -v -p codesigning`);
# default is ad-hoc ("-"), which runs on this Mac but not as a distributable build.
# GRAVITTY_NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile name) also notarizes, staples and zips it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)/Gravitty

# GRAVITTY_VERSION / GRAVITTY_BUILD set the version (Sparkle compares the build number, so it must grow every release).
# GRAVITTY_FEED_URL points the update check somewhere else, for testing against a local server (adds a local-network exception).
VERSION="${GRAVITTY_VERSION:-0.1.0}"
BUILD="${GRAVITTY_BUILD:-1}"
FEED="${GRAVITTY_FEED_URL:-https://github.com/pinkdonutstudio/gravitty/releases/latest/download/appcast.xml}"
ATS=""
[ -n "${GRAVITTY_FEED_URL:-}" ] && ATS="<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>"

# APP_DIR (default build) lets a test build leave build/Gravitty.app alone.
APP="${APP_DIR:-build}/Gravitty.app"
SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Gravitty"

# Sparkle (auto-update). The XPC services are only for sandboxed apps, so they are dropped, which also leaves less to sign.
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Gravitty"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.pinkdonutstudio.gravitty</string>
  <key>CFBundleName</key><string>Gravitty</string>
  <key>CFBundleExecutable</key><string>Gravitty</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>$FEED</string>
  $ATS
  <key>SUPublicEDKey</key><string>dD5PhfvsbW+V3hQQ1w59Gk8QPHrqN+YvWwuPAmty9cU=</string>
  <key>SUEnableSystemProfiling</key><false/>
</dict></plist>
PLIST

# Inside out: Sparkle's helpers, then the framework, then the app.
SIGN="${GRAVITTY_SIGN_ID:--}"
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --options runtime --sign "$SIGN" "$FW/Autoupdate" "$FW/Updater.app"
codesign --force --options runtime --sign "$SIGN" "$APP/Contents/Frameworks/Sparkle.framework"
# An ad-hoc build has no team id, so the hardened runtime would refuse to load Sparkle (different team ids). Only for ad-hoc.
ENT=()
if [ "$SIGN" = "-" ]; then
  ENT_FILE=$(mktemp)
  cat > "$ENT_FILE" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
XML
  ENT=(--entitlements "$ENT_FILE")
fi
codesign --force --options runtime ${ENT[@]+"${ENT[@]}"} --sign "$SIGN" "$APP"
codesign --verify --strict --verbose=1 "$APP"

if [ -n "${GRAVITTY_NOTARY_PROFILE:-}" ]; then
  ZIP="$(dirname "$APP")/Gravitty.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$GRAVITTY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP" # re-zip with the ticket stapled in
  spctl --assess --type execute -v "$APP"           # what Gatekeeper will say on another Mac
fi
echo "built $APP"
