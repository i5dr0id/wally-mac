#!/bin/bash
# Build, bundle, sign and install LiveWallpaper, then restart it.
set -euo pipefail

cd "$(dirname "$0")"
APP="$HOME/Applications/LiveWallpaper.app"
SAVER="$HOME/Library/Screen Savers/WallyClock.saver"
# The clock font and wallpaper bundled into the screen saver (Concentric's
# git-ignored public/local folder). Without them it falls back to a system font
# on plain teal.
CLOCK_ASSETS="${CLOCK_ASSETS:-$HOME/.i5dr0id/concentric/public/local}"
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
# A copy started outside launchd (Finder, `open`) survives the bootout, and the
# single-instance guard would then make the freshly installed copy exit at once.
pkill -f 'LiveWallpaper.app/Contents/MacOS/LiveWallpaper' 2>/dev/null || true
sleep 1
rm -rf "$APP"
mkdir -p "$HOME/Applications"
cp -R build/LiveWallpaper.app "$APP"

echo "==> (re)loading login agent"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
launchctl enable "gui/$(id -u)/local.LiveWallpaper" 2>/dev/null || true

echo "==> screen saver"
swiftc -O -parse-as-library -module-name WallyClock -Xlinker -bundle \
       -framework ScreenSaver -framework QuartzCore \
       -o build/WallyClock saver/WallyClockView.swift
rm -rf build/WallyClock.saver
mkdir -p build/WallyClock.saver/Contents/{MacOS,Resources}
cp build/WallyClock build/WallyClock.saver/Contents/MacOS/
cp saver/Info.plist build/WallyClock.saver/Contents/Info.plist
for f in SFStencilNumeric.ttf wallpaper.jpg; do
  if [ -f "$CLOCK_ASSETS/$f" ]; then
    cp "$CLOCK_ASSETS/$f" build/WallyClock.saver/Contents/Resources/
  else
    echo "    note: $CLOCK_ASSETS/$f not found; using the fallback"
  fi
done
codesign --force --deep -s - build/WallyClock.saver
codesign -v build/WallyClock.saver
mkdir -p "$(dirname "$SAVER")"
rm -rf "$SAVER"
cp -R build/WallyClock.saver "$SAVER"
# The saver host caches loaded bundles; restart it so the new build is used.
killall legacyScreenSaver 2>/dev/null || true
echo "    installed $SAVER"

echo "==> done: $(pgrep -f 'LiveWallpaper.app/Contents/MacOS' | head -1)"
