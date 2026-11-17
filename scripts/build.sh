#!/bin/bash
# Build Veil.app from the SwiftPM target.
#   scripts/build.sh            → build + ad-hoc sign + install to /Applications (local dev)
#   scripts/build.sh release    → Developer ID sign (hardened runtime), notarize if
#                                 the notarytool keychain profile ($NOTARY_PROFILE, default candela-notary — same Apple team) works, then DMG.
set -euo pipefail
NAME="Veil"; ID="dev.jamesai.veil"; VERSION="${VERSION:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$NAME"
APP="$ROOT/build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
$(cat "$ROOT/Info-extra.xml" 2>/dev/null)
</dict></plist>
PLIST
xattr -cr "$APP"

if [ "${1:-}" != "release" ]; then
  codesign --force --deep -s - "$APP"
  pkill -x "$NAME" 2>/dev/null || true
  rm -rf "/Applications/$NAME.app"; cp -R "$APP" "/Applications/$NAME.app"
  echo "Installed /Applications/$NAME.app"; exit 0
fi

SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
[ -n "$SIGN_ID" ] || { echo "No Developer ID Application identity in the keychain"; exit 1; }
codesign --force --options runtime --timestamp --entitlements "$ROOT/scripts/$NAME.entitlements" --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Stable DMG name so releases/latest/download/<Name>.dmg always works.
DMG="$ROOT/build/$NAME.dmg"; STAGE="$ROOT/build/dmg"
notarize() {  # $1 = file. Skipped (with a warning) when the profile can't submit.
  xcrun notarytool submit "$1" --keychain-profile "${NOTARY_PROFILE:-candela-notary}" --wait \
    && xcrun stapler staple "$1"
}
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
notarize "$DMG" || echo "WARNING: notarization skipped/failed — DMG is signed but NOT notarized"
echo "DMG: $DMG"
