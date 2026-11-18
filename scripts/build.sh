#!/bin/bash
# Build Veil.app from the SwiftPM target.
#   scripts/build.sh            → build + ad-hoc sign + install to /Applications (local dev)
#   scripts/build.sh release    → Developer ID sign (hardened runtime), notarize if
#                                 the notarytool keychain profile ($NOTARY_PROFILE, default candela-notary — same Apple team) works, then DMG.
set -euo pipefail
NAME="Veil"; ID="dev.jamesai.veil"; VERSION="${VERSION:-1.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BIN="$BIN_DIR/$NAME"
APP="$ROOT/build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# Sparkle.framework (universal) from the SwiftPM build products; the binary's
# rpath @executable_path/../Frameworks (see Package.swift) finds it here.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Localisation (en, zh-Hans, zh-Hant .lproj folders) and the welcome-guide screenshots.
for d in Resources/*.lproj; do ditto "$d" "$APP/Contents/Resources/$(basename "$d")"; done
[ -d Resources/Onboarding ] && ditto Resources/Onboarding "$APP/Contents/Resources/Onboarding"
python3 "$ROOT/scripts/check_strings.py" >/dev/null || { echo "Localisation check failed — run scripts/check_strings.py"; exit 1; }
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
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

# Sign Sparkle's nested code inside-out (XPC services, Updater.app, Autoupdate,
# then the framework) BEFORE sealing the app; notarization rejects any other order.
# $1 = identity ("-" for ad hoc); remaining args = extra codesign flags.
sign_sparkle() {
  local id="$1"; shift
  local fw="$APP/Contents/Frameworks/Sparkle.framework" x
  for x in "$fw"/Versions/B/XPCServices/*.xpc; do [ -e "$x" ] && codesign --force "$@" --sign "$id" "$x"; done
  [ -e "$fw/Versions/B/Updater.app" ] && codesign --force "$@" --sign "$id" "$fw/Versions/B/Updater.app"
  [ -e "$fw/Versions/B/Autoupdate" ] && codesign --force "$@" --sign "$id" "$fw/Versions/B/Autoupdate"
  codesign --force "$@" --sign "$id" "$fw"
}

if [ "${1:-}" != "release" ]; then
  sign_sparkle -
  codesign --force --deep -s - "$APP"
  pkill -x "$NAME" 2>/dev/null || true
  rm -rf "/Applications/$NAME.app"; cp -R "$APP" "/Applications/$NAME.app"
  echo "Installed /Applications/$NAME.app"; exit 0
fi

SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
[ -n "$SIGN_ID" ] || { echo "No Developer ID Application identity in the keychain"; exit 1; }
sign_sparkle "$SIGN_ID" --options runtime --timestamp
codesign --force --options runtime --timestamp --entitlements "$ROOT/scripts/$NAME.entitlements" --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Stable DMG name (<Name>.dmg) on every release; Sparkle's appcast points at the versioned tag path.
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

# Sparkle: staple/notarization must have succeeded before the DMG is advertised as an update.
GK="$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 || true)"
if grep -q "source=Notarized Developer ID" <<<"$GK"; then
  python3 "$ROOT/scripts/update_appcast.py" --appcast "$ROOT/appcast.xml" --dmg "$DMG" \
    --version "$VERSION" --build "$VERSION" \
    --url "https://github.com/iamzifei/veil/releases/download/v$VERSION/$NAME.dmg" \
    --sign-tool "${SIGN_UPDATE:-/Users/james/Dev/candela/vendor/bin/sign_update}" --min-system 14.0
  echo "appcast.xml updated — commit it and publish the v$VERSION release with $NAME.dmg"
else
  echo "WARNING: DMG not notarized/accepted by Gatekeeper — appcast.xml NOT updated"
fi
