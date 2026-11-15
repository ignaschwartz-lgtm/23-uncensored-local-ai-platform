#!/bin/sh
# Builds 23.app and installs it into /Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/23.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TwentyThree "$APP/Contents/MacOS/TwentyThree"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The icon is a layered Icon Composer document: the system lights it and re-tints it for dark, clear and tinted modes.
# Without Xcode's actool, fall back to the flat picture.
if xcrun -f actool >/dev/null 2>&1 && xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
     --app-icon AppIcon --platform macosx --minimum-deployment-target 26.0 \
     --output-partial-info-plist build/icon.plist >/dev/null 2>&1 && [ -f "$APP/Contents/Resources/Assets.car" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
else
  [ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
fi
# The voice server script (Kokoro), started by 23 when it speaks.
cp Resources/helpers/kokoro_server.py "$APP/Contents/Resources/"
# A plain `ps` for add-on servers in the sandbox (macOS's own needs privileges a sandboxed program can't use).
mkdir -p "$APP/Contents/Helpers"
swiftc -O Resources/helpers/ps.swift -o "$APP/Contents/Helpers/ps"
# Sign with a local identity called "23 Local Signing" if you made one (macOS then keeps its permissions across
# rebuilds); otherwise ad-hoc, which works the same but asks for permissions again after each rebuild.
IDENTITY="-"
security find-identity -p codesigning 2>/dev/null | grep -q "23 Local Signing" && IDENTITY="23 Local Signing"
codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/ps"
codesign --force --sign "$IDENTITY" --identifier local.twentythree "$APP"
pkill -x TwentyThree 2>/dev/null || true
rm -rf /Applications/23.app
cp -R "$APP" /Applications/23.app
echo "Installed /Applications/23.app"
