#!/bin/bash
# Builds "Ultimate Brain Stimulation.app" and installs it in ~/Applications.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
NAME="Ultimate Brain Stimulation"
DEST="$HOME/Applications/$NAME.app"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

APP="$BUILD/$NAME.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/BrainStim" "$HERE/main.swift"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.bryanfrds.ultimate-brain-stimulation</string>
  <key>CFBundleExecutable</key><string>BrainStim</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>UBSPath</key><string>$REPO/bin/ubs</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
pkill -f "$NAME.app/Contents/MacOS/BrainStim" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
