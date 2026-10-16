#!/bin/bash
# Build, bundle, sign and install LiveWallpaper, then restart it.
set -euo pipefail

cd "$(dirname "$0")"
APP="$HOME/Applications/LiveWallpaper.app"
SAVER="$HOME/Library/Screen Savers/WallyClock.saver"
# Built web page bundled into the screen saver (Concentric's `npm run build:saver`).
CLOCK_WEB="${CLOCK_WEB:-$HOME/.i5dr0id/concentric/dist-saver}"
CLOCK_PAGE="${CLOCK_PAGE:-mac-left}"
AGENT="$HOME/Library/LaunchAgents/local.LiveWallpaper.plist"

echo "==> compiling"
swiftc -O -o LiveWallpaper main.swift WebContent.swift

echo "==> bundling"
rm -rf build/LiveWallpaper.app
mkdir -p build/LiveWallpaper.app/Contents/{MacOS,Resources}
cp LiveWallpaper build/LiveWallpaper.app/Contents/MacOS/
cp main.swift WebContent.swift README.md build/LiveWallpaper.app/Contents/Resources/ 2>/dev/null || true
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

echo "==> screen saver"
if [ -d "$CLOCK_WEB" ]; then
  swiftc -O -parse-as-library -module-name WallyClock -Xlinker -bundle \
         -framework ScreenSaver -framework WebKit \
         -o build/WallyClock saver/WallyClockView.swift WebContent.swift
  rm -rf build/WallyClock.saver
  mkdir -p build/WallyClock.saver/Contents/{MacOS,Resources}
  cp build/WallyClock build/WallyClock.saver/Contents/MacOS/
  cp saver/Info.plist build/WallyClock.saver/Contents/Info.plist
  plutil -replace WallyClockPage -string "$CLOCK_PAGE" build/WallyClock.saver/Contents/Info.plist
  cp -R "$CLOCK_WEB" build/WallyClock.saver/Contents/Resources/web
  codesign --force --deep -s - build/WallyClock.saver
  codesign -v build/WallyClock.saver
  mkdir -p "$(dirname "$SAVER")"
  rm -rf "$SAVER"
  cp -R build/WallyClock.saver "$SAVER"
  # The saver host caches loaded bundles; restart it so the new build is used.
  killall legacyScreenSaver 2>/dev/null || true
  echo "    installed $SAVER (page: $CLOCK_PAGE)"
else
  echo "    skipped: no web build at $CLOCK_WEB (set CLOCK_WEB to a built page folder)"
fi

echo "==> done: $(pgrep -f 'LiveWallpaper.app/Contents/MacOS' | head -1)"
