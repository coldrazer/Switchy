#!/bin/sh
# Wrap build/Switchy.app in a drag-to-Applications disk image:
#   ./make_dmg.sh              build the app, then build/Switchy-<version>.dmg
#   ./make_dmg.sh --no-build   reuse the app already in build/
# The app and the image are ad-hoc signed only; notarize both for distribution.
set -eu
cd "$(dirname "$0")"
NAME="Switchy"

if [ "${1:-}" != "--no-build" ]; then
  ./make_app.sh
fi

APP="build/$NAME.app"
[ -d "$APP" ] || { echo "no $APP; run ./make_app.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/$NAME-$VERSION.dmg"
STAGE="build/.dmg-stage"
RW="build/.$NAME-rw.dmg"
MNT="/Volumes/$NAME"

cleanup() {
  hdiutil detach "$MNT" -force >/dev/null 2>&1 || true
  # rmdir, never rm -rf: if the detach failed, the mount point still holds the mounted volume.
  rmdir "$MNT" 2>/dev/null || true
  rm -rf "$STAGE" "$RW"
}
trap cleanup EXIT

rm -rf "$STAGE" "$DMG"
# Finder only sees volumes mounted under /Volumes; refuse to stack a second one.
if mount | grep -q " on $MNT "; then
  echo "a volume named $NAME is already mounted at $MNT; detach it first" >&2
  exit 1
fi
rmdir "$MNT" 2>/dev/null || true
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$NAME.app"
cp dmg-background.png "$STAGE/.background/background.png"
ln -s /Applications "$STAGE/Applications"

# Writable image first: the Finder layout lives in .DS_Store, which needs a mounted volume to write.
hdiutil create -srcfolder "$STAGE" -volname "$NAME" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -noverify -noautoopen -readwrite >/dev/null

osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "$NAME.app" of container window to {170, 200}
        set position of item "Applications" of container window to {470, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Same artwork as the volume icon.
cp AppIcon.icns "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT" 2>/dev/null || true

sync
sleep 1
hdiutil detach "$MNT" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "$DMG"
ls -lh "$DMG" | awk '{print $5}'
shasum -a 256 "$DMG"
