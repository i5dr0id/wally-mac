#!/bin/bash
# Build a compressed .dmg from the staged package produced by package.sh.
set -euo pipefail

cd "$(dirname "$0")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
STAGE="dist/LiveWallpaper-$VERSION"
DMG="dist/LiveWallpaper-$VERSION.dmg"
VOLNAME="LiveWallpaper $VERSION"

if [ ! -d "$STAGE/LiveWallpaper.app" ]; then
    echo "==> staging not found, running package.sh first"
    ./package.sh >/dev/null
fi

# Lay out the image: the app, a drop target, and the scripts.
ROOT="$(mktemp -d)/LiveWallpaper"
mkdir -p "$ROOT"
cp -R "$STAGE/LiveWallpaper.app" "$ROOT/"
cp "$STAGE/install.sh" "$STAGE/uninstall.sh" "$STAGE/README.md" "$ROOT/"
ln -s /Applications "$ROOT/Applications"

cat > "$ROOT/READ ME FIRST.txt" <<'TXT'
LiveWallpaper
=============

Recommended — open Terminal here and run:

    ./install.sh

It installs to ~/Applications, starts the app, and sets it to launch at login.
It also clears the quarantine flag macOS attaches to anything copied between
machines, which otherwise causes Gatekeeper to block the app.

Alternative — drag LiveWallpaper.app onto the Applications shortcut.
Because this app is signed ad-hoc rather than with a paid Apple Developer ID,
the first launch will be blocked. Approve it once in:

    System Settings > Privacy & Security > "Open Anyway"

Then use the menu bar icon > Launch at Login.

Either way, pick a video with:
    menu bar icon > Desktop Wallpaper > Choose File...

For the screen saver and lock screen, first select any Aerial in
System Settings > Wallpaper, then use the "Screen Saver & Lock Screen" menu.

To remove it, run ./uninstall.sh
TXT

echo "==> building $DMG"
rm -f "$DMG"
# macOS 26+ deprecates the hdiutil verbs in favour of `diskutil image`; fall back
# so this still builds on an older Mac.
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName "$VOLNAME" "$ROOT" "$DMG" >/dev/null
else
    hdiutil create -volname "$VOLNAME" -srcfolder "$ROOT" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
fi

rm -rf "$(dirname "$ROOT")"

# Mount the finished image and check the app inside really is universal and
# validly signed — a stronger check than a checksum, and it catches a bundle
# broken by the copy or the compression.
echo "==> verifying"
MP="$(mktemp -d)"
if diskutil image attach --readOnly --nobrowse --mountPoint "$MP" "$DMG" >/dev/null 2>&1; then
    trap 'diskutil eject "$MP" >/dev/null 2>&1 || true' EXIT
    test -d "$MP/LiveWallpaper.app" || { echo "    FAIL: app missing"; exit 1; }
    lipo -info "$MP/LiveWallpaper.app/Contents/MacOS/LiveWallpaper" | sed 's/^/    /'
    codesign -v "$MP/LiveWallpaper.app" && echo "    signature ok"
    test -x "$MP/install.sh" || { echo "    FAIL: install.sh not executable"; exit 1; }
    echo "    contents ok"
    diskutil eject "$MP" >/dev/null 2>&1 || true
    trap - EXIT
else
    echo "    FAIL: could not attach image" >&2
    exit 1
fi
rmdir "$MP" 2>/dev/null || true

echo
echo "Disk image: $(pwd)/$DMG"
du -h "$DMG" | cut -f1
