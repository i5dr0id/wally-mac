#!/bin/bash
# Install LiveWallpaper for the current user. Safe to re-run.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/LiveWallpaper.app"
AGENT="$HOME/Library/LaunchAgents/local.LiveWallpaper.plist"
UID_NUM="$(id -u)"

if [ ! -d "$SRC/LiveWallpaper.app" ]; then
    echo "error: LiveWallpaper.app not found next to this script." >&2
    exit 1
fi

echo "==> stopping any running copy"
launchctl bootout "gui/$UID_NUM/local.LiveWallpaper" 2>/dev/null || true
pkill -f 'LiveWallpaper.app/Contents/MacOS' 2>/dev/null || true

echo "==> installing to $APP"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
cp -R "$SRC/LiveWallpaper.app" "$APP"

# Copying between Macs attaches a quarantine flag; without clearing it the
# ad-hoc signature trips Gatekeeper and the app is killed on launch.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Re-sign locally: an ad-hoc signature is tied to the bits, and stripping the
# quarantine xattr is cleaner than asking the user to right-click → Open.
codesign --force --deep -s - "$APP"
codesign -v "$APP" && echo "    signature ok"

echo "==> writing login agent"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.LiveWallpaper</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/LiveWallpaper</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>/tmp/LiveWallpaper.err.log</string>
</dict>
</plist>
PLIST
plutil -lint "$AGENT" >/dev/null

echo "==> starting"
launchctl bootstrap "gui/$UID_NUM" "$AGENT"
launchctl enable "gui/$UID_NUM/local.LiveWallpaper" 2>/dev/null || true

sleep 2
if pgrep -f 'LiveWallpaper.app/Contents/MacOS' >/dev/null; then
    echo
    echo "Installed and running. Look for the picture icon in the menu bar."
    echo "Pick a video with:  menu bar icon › Desktop Wallpaper › Choose File…"
    echo
    echo "For the screen saver and lock screen, first choose any Aerial in"
    echo "System Settings › Wallpaper, then use the Screen Saver & Lock Screen menu."
else
    echo "warning: it did not stay running. See /tmp/LiveWallpaper.err.log" >&2
    exit 1
fi
