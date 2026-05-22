#!/usr/bin/env bash
# Build macosAsrApp.app without full Xcode.app (swiftc + bundle layout).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSASR_ROOT="$ROOT"
APP_NAME="macosAsrApp"
BUILD_DIR="$ROOT/MacApp/build"
APP="$BUILD_DIR/$APP_NAME.app"
SRC="$ROOT/MacApp/macosAsrApp"

mkdir -p "$BUILD_DIR"
PLIST="$SRC/Info.plist"
swiftc -Onone \
  -target arm64-apple-macosx15.0 \
  -framework Cocoa \
  -framework ApplicationServices \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" \
  "$SRC/main.swift" \
  "$SRC/AppLogger.swift" \
  "$SRC/ProjectPaths.swift" \
  "$SRC/TextInjector.swift" \
  "$SRC/InjectionStateMachine.swift" \
  "$SRC/MockInjectionTest.swift" \
  "$SRC/DaemonClient.swift" \
  "$SRC/DaemonManager.swift" \
  "$SRC/LiveDictationController.swift" \
  "$SRC/AppDelegate.swift" \
  -o "$BUILD_DIR/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/macosAsrApp.entitlements" "$APP/Contents/Resources/macosAsrApp.entitlements"

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.macosasr.app" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string macosAsr" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName macosAsr" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$PLIST"

chmod +x "$APP/Contents/MacOS/$APP_NAME"

#  ad-hoc 签名，便于出现在「辅助功能」列表
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi
echo "Built: $APP"
echo "Run: open --env MACOSASR_ROOT=$ROOT \"$APP\""
