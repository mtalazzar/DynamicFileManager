#!/bin/bash
# Builds DynamicFileConverter.app (release) and installs it in /Applications.
#   scripts/build-app.sh            build + install + launch
#   scripts/build-app.sh --no-install
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/DynamicFileConverter.app"

echo "▸ Building (release)…"
swift build -c release --product DynamicFileConverter
swift build -c release --product dfc
BIN="$(swift build -c release --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DynamicFileConverter" "$APP/Contents/MacOS/"
cp "$BIN/dfc" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/"

ICONSET="$ROOT/build/AppIcon.iconset"
if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  echo "▸ Drawing icon"
  rm -rf "$ICONSET"
  swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

if [ "${1:-}" != "--no-install" ]; then
  echo "▸ Installing to /Applications"
  pkill -x DynamicFileConverter 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/DynamicFileConverter.app"
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/DynamicFileConverter.app
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  open /Applications/DynamicFileConverter.app
  echo "✓ Installed and launched. Look for the ◎ icon in the menu bar."
fi
