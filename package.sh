#!/bin/bash
# Build a universal (Apple Silicon + Intel) LiveWallpaper.app and zip it up with
# an installer, ready to copy to another Mac.
set -euo pipefail

cd "$(dirname "$0")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
STAGE="dist/LiveWallpaper-$VERSION"
DEPLOY_TARGET="13.0"

echo "==> compiling universal binary (arm64 + x86_64)"
rm -rf dist build/universal
mkdir -p build/universal "$STAGE"
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos$DEPLOY_TARGET" \
           -o "build/universal/LiveWallpaper.$arch" main.swift
done
lipo -create -output build/universal/LiveWallpaper \
     build/universal/LiveWallpaper.arm64 build/universal/LiveWallpaper.x86_64
lipo -info build/universal/LiveWallpaper

echo "==> bundling"
APP="$STAGE/LiveWallpaper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/universal/LiveWallpaper "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/Info.plist"
cp main.swift README.md build.sh Info.plist "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> signing"
codesign --force --deep -s - "$APP"
codesign -v "$APP"

cp install.sh uninstall.sh README.md "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"

echo "==> zipping"
( cd dist && ditto -c -k --sequesterRsrc --keepParent \
    "LiveWallpaper-$VERSION" "LiveWallpaper-$VERSION.zip" )

echo
echo "Package: $(pwd)/dist/LiveWallpaper-$VERSION.zip"
du -h "dist/LiveWallpaper-$VERSION.zip" | cut -f1
