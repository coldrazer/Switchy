#!/bin/sh
# Developer ID sign, notarize and staple the release image.
#   DEV_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=switchy ./notarize.sh
# The profile is created once with: xcrun notarytool store-credentials switchy --apple-id … --team-id … --password …
set -eu
cd "$(dirname "$0")"
: "${DEV_ID:?set DEV_ID to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to an xcrun notarytool keychain profile}"

CODESIGN_IDENTITY="$DEV_ID" ./make_app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Switchy.app/Contents/Info.plist)"
DMG="build/Switchy-$VERSION.dmg"
./make_dmg.sh --no-build

codesign --force --timestamp --sign "$DEV_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
echo "notarized: $DMG"
