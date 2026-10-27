#!/bin/bash
# Builds PhoneLensCamera.app (+ embedded .systemextension) with swiftc only.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/phonelens-camera
APP="$OUT/PhoneLensCamera.app"
DEVID="Apple Development: v99sam@gmail.com (93G5Z94VHX)"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
  "$APP/Contents/Library/SystemExtensions"

echo "== host =="
xcrun swiftc -parse-as-library -O \
  -o "$APP/Contents/MacOS/PhoneLensCamera" \
  "$ROOT/PhoneLensCamera/main.swift" \
  "$ROOT/PhoneLensCamera/StreamCore.swift" \
  "$ROOT/PhoneLensCamera/SlotWriter.swift" \
  -framework AVFoundation -framework AppKit -framework CoreMedia \
  -framework CoreVideo -framework Foundation -framework SystemExtensions \
  -framework IOSurface -framework CoreImage
cp "$ROOT/PhoneLensCamera/Info.plist" "$APP/Contents/Info.plist"

echo "== extension =="
EXT="$APP/Contents/Library/SystemExtensions/tw.phonecamera.phonelens.frame.systemextension"
mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
xcrun swiftc -O \
  -o "$EXT/Contents/MacOS/PhoneLensCameraExt" \
  "$ROOT/PhoneLensCameraExt/main.swift" \
  "$ROOT/PhoneLensCameraExt/PhoneLensCameraProvider.swift" \
  "$ROOT/Shared/FrameIPC.swift" \
  -framework CoreMediaIO -framework Foundation -framework IOSurface \
  -framework CoreMedia -framework CoreVideo -framework IOKit
cp "$ROOT/PhoneLensCameraExt/Info.plist" "$EXT/Contents/Info.plist"

echo "== sign =="
codesign --force --sign "$DEVID" \
  --entitlements "$ROOT/PhoneLensCameraExt/PhoneLensCameraExt.entitlements" \
  "$EXT/Contents/MacOS/PhoneLensCameraExt"
codesign --force --sign "$DEVID" \
  --entitlements "$ROOT/PhoneLensCamera/PhoneLensCamera.entitlements" \
  "$APP/Contents/MacOS/PhoneLensCamera"
codesign --force --sign "$DEVID" "$APP"
echo "== verify =="
codesign -dvv "$APP" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier"
codesign -dvv "$EXT" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier"
echo "BUILD OK: $APP"
