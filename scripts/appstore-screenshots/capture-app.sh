#!/bin/zsh
# Captures the two app screens of the store set into docs/appstore/raw/:
#   04-app-home.png      Home (省下的時間)
#   05-app-settings.png  Settings (speech engines and keys)
#
# Creates a temporary iPhone 17 Pro Max simulator (zh-TW, light, 9:41 status bar), builds the
# Debug app, launches it with the DEBUG demo flags and takes screenshots, then deletes the
# simulator. Nothing is recorded: no microphone permission is granted, nothing is tapped, and
# the keys shown as "已設定" are a display-only DEBUG flag (-ScriberDemoReady).
#
# Usage: scripts/appstore-screenshots/capture-app.sh
#   RUNTIME / DEVICE / DERIVED_DATA override the defaults below.
set -euo pipefail

ROOT=${0:A:h:h:h}
RAW=$ROOT/docs/appstore/raw
RUNTIME=${RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}
DEVICE=${DEVICE:-"iPhone 17 Pro Max"}
WORK=$(mktemp -d)
DERIVED_DATA=${DERIVED_DATA:-$WORK/dd}
BUNDLE=com.geekaz.Scriber

UDID=$(xcrun simctl create "Scriber Store Shots" "$DEVICE" "$RUNTIME")
cleanup() {
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
echo "simulator $UDID"

# Boot headless (Simulator.app is not opened), switch to zh-TW, reboot to apply.
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl spawn "$UDID" defaults write "Apple Global Domain" AppleLanguages -array zh-Hant-TW en
xcrun simctl spawn "$UDID" defaults write "Apple Global Domain" AppleLocale zh_TW
xcrun simctl shutdown "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl ui "$UDID" appearance light

xcodebuild -project "$ROOT/Scriber.xcodeproj" -scheme Scriber -destination "id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" build CODE_SIGNING_ALLOWED=NO -quiet
xcrun simctl install "$UDID" "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Scriber.app"

shot() {
  local file=$1; shift
  xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" $BUNDLE -ScriberSkipOnboarding YES -ScriberDemo YES -ScriberDemoReady YES "$@" >/dev/null
  sleep 8
  # simctl writes through the CoreSimulator service: capture to a temp file, then copy.
  xcrun simctl io "$UDID" screenshot "$WORK/$file" >/dev/null 2>&1
  cp "$WORK/$file" "$RAW/$file"
  echo "captured $file"
}

mkdir -p "$RAW"
shot 04-app-home.png -ScriberTab home   # the first launch after install is slow: warm-up, retaken below
shot 04-app-home.png -ScriberTab home
shot 05-app-settings.png -ScriberTab settings
xcrun simctl terminate "$UDID" $BUNDLE >/dev/null 2>&1 || true
