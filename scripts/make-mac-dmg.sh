#!/bin/bash
# Packages the notarized macOS app into build/dist/Scriber-<version>.dmg.
# Run after `xcodebuild -exportNotarizedApp` succeeded (see docs/MAC_RELEASE.md).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/mac-archive/notarized/Scriber.app"
[ -d "$APP" ] || { echo "No notarized app at $APP"; exit 1; }
xcrun stapler validate "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Scriber.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p build/dist
DMG="build/dist/Scriber-$VERSION.dmg"
hdiutil create -volname "Scriber" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign -s "Developer ID Application: Geekaz LLC" --timestamp "$DMG"
spctl -a -vv "$APP"
echo "Created $DMG"
