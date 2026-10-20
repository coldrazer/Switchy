#!/bin/sh
# Wrap the SwiftPM executable in an app bundle: build/Switchy.app (ad-hoc signed; notarize for releases).
#   ./make_app.sh            release build
#   ./make_app.sh debug      debug build
set -eu
cd "$(dirname "$0")"
# SwiftUI's @State is a macro and its plugin ships with Xcode, not the Command Line Tools. If Xcode is installed but
# not the selected developer dir, use it for this build instead of failing with "plugin for module 'SwiftUIMacros'".
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  export DEVELOPER_DIR
fi
CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Switchy"
APP="build/Switchy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Switchy"
# SwiftPM keeps the resources in a bundle next to the executable; Bundle.module looks for it in Contents/Resources.
RES="$(dirname "$BIN")/Switchy_Switchy.bundle"
if [ -d "$RES" ]; then cp -R "$RES" "$APP/Contents/Resources/"; fi
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.coldrazer.switchy</string>
  <key>CFBundleName</key><string>Switchy</string>
  <key>CFBundleDisplayName</key><string>Switchy</string>
  <key>CFBundleExecutable</key><string>Switchy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>GCSupportsControllerUserInteraction</key><true/>
</dict></plist>
PLIST
# Ad-hoc by default; notarize.sh passes a Developer ID and asks for the hardened runtime.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "$APP"
