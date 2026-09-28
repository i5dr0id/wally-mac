#!/bin/bash
# Remove LiveWallpaper for the current user.
# Restore Apple's Aerial from the menu FIRST if you used the screen saver feature.
set -euo pipefail

UID_NUM="$(id -u)"
APP="$HOME/Applications/LiveWallpaper.app"
AGENT="$HOME/Library/LaunchAgents/local.LiveWallpaper.plist"

echo "==> stopping"
launchctl bootout "gui/$UID_NUM/local.LiveWallpaper" 2>/dev/null || true
pkill -f 'LiveWallpaper.app/Contents/MacOS' 2>/dev/null || true

echo "==> removing files"
rm -rf "$APP"
rm -f "$AGENT"
defaults delete local.LiveWallpaper 2>/dev/null || true

VIDEOS="$HOME/Library/Application Support/com.apple.wallpaper/aerials/videos"
if ls "$VIDEOS"/*.mov.apple-original >/dev/null 2>&1; then
    echo
    echo "note: a swapped screen saver video is still in place."
    echo "      Apple's original is preserved here:"
    ls -1 "$VIDEOS"/*.mov.apple-original
    echo "      To restore it, unlock and swap back, e.g.:"
    echo "        chflags nouchg \"$VIDEOS/<id>.mov\""
    echo "        mv \"$VIDEOS/<id>.mov.apple-original\" \"$VIDEOS/<id>.mov\""
    echo "        killall WallpaperAgent"
fi

echo "done — the desktop falls back to the macOS wallpaper."
