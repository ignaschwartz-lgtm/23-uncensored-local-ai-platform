#!/bin/sh
# Builds 23.app and zips it for a release (build/23.zip), without installing it.
# Signed ad-hoc: people opening it allow it once in System Settings › Privacy & Security.
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=build/23.app
rm -rf "$APP" build/23.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/TwentyThree "$APP/Contents/MacOS/TwentyThree"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if xcrun -f actool >/dev/null 2>&1 && xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
     --app-icon AppIcon --platform macosx --minimum-deployment-target 26.0 \
     --output-partial-info-plist build/icon.plist >/dev/null 2>&1 && [ -f "$APP/Contents/Resources/Assets.car" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
else
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
cp Resources/helpers/kokoro_server.py "$APP/Contents/Resources/"
swiftc -O Resources/helpers/ps.swift -o "$APP/Contents/Helpers/ps"
codesign --force --sign - "$APP/Contents/Helpers/ps"
codesign --force --sign - --identifier local.twentythree "$APP"
ditto -c -k --keepParent "$APP" build/23.zip
shasum -a 256 build/23.zip
