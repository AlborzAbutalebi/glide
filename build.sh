#!/bin/bash
# Build Glide.app, sign it, install it to ~/Applications and start it.
#   ./build.sh               build, install and launch
#   ./build.sh --no-install  only build build/Glide.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Glide

APP=build/Glide.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Glide "$APP/Contents/MacOS/Glide"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  echo "Drawing the app icon…"
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift Scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with your Apple Development certificate when there is one: macOS then keeps
# Glide's Accessibility permission across rebuilds. Otherwise sign ad hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$APP"
if [ -n "$IDENTITY" ]; then echo "Built $APP (signed with your development certificate)"; else echo "Built $APP (signed ad hoc)"; fi

if [ "${1:-}" != "--no-install" ]; then
  if pgrep -x Glide >/dev/null; then
    osascript -e 'quit app "Glide"' 2>/dev/null || pkill -x Glide || true
    sleep 1
  fi
  mkdir -p ~/Applications
  rm -rf ~/Applications/Glide.app
  ditto "$APP" ~/Applications/Glide.app
  open ~/Applications/Glide.app
  echo "Installed to ~/Applications/Glide.app and started it."
fi
