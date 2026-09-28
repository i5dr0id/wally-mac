#!/bin/bash
# Build, bundle, sign and install LiveWallpaper, then restart it.
set -euo pipefail

cd "$(dirname "$0")"
APP="$HOME/Applications/LiveWallpaper.app"
AGENT="$HOME/Library/LaunchAgents/local.LiveWallpaper.plist"

echo "==> compiling"
swiftc -O -o LiveWallpaper main.swift

echo "==> bundling"
rm -rf build/LiveWallpaper.app
mkdir -p build/LiveWallpaper.app/Contents/{MacOS,Resources}
cp LiveWallpaper build/LiveWallpaper.app/Contents/MacOS/
cp main.swift README.md build/LiveWallpaper.app/Contents/Resources/ 2>/dev/null || true
cp Info.plist build/LiveWallpaper.app/Contents/Info.plist
plutil -lint build/LiveWallpaper.app/Contents/Info.plist >/dev/null

echo "==> signing"
codesign --force --deep -s - build/LiveWallpaper.app
codesign -v build/LiveWallpaper.app

echo "==> installing to $APP"
launchctl bootout "gui/$(id -u)/local.LiveWallpaper" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$HOME/Applications"
cp -R build/LiveWallpaper.app "$APP"

echo "==> (re)loading login agent"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl enable "gui/$(id -u)/local.LiveWallpaper" 2>/dev/null || true

echo "==> done: $(pgrep -f 'LiveWallpaper.app/Contents/MacOS' | head -1)"
