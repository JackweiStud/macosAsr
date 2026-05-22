#!/usr/bin/env bash
# Build macosAsrApp.app (swiftc + bundle layout; Command Line Tools only).
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
  "$SRC/AppConfig.swift" \
  "$SRC/ConfigManager.swift" \
  "$SRC/SettingsWindowController.swift" \
  "$SRC/AppLogger.swift" \
  "$SRC/ProjectPaths.swift" \
  "$SRC/TextInjector.swift" \
  "$SRC/InjectionStateMachine.swift" \
  "$SRC/DaemonClient.swift" \
  "$SRC/DaemonManager.swift" \
  "$SRC/LiveDictationController.swift" \
  "$SRC/GlobalHotkeyMonitor.swift" \
  "$SRC/AppDelegate.swift" \
  -o "$BUILD_DIR/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$ROOT/scripts/build_icon.sh"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/macosAsrApp.entitlements" "$APP/Contents/Resources/macosAsrApp.entitlements"
cp "$ROOT/MacApp/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.macosasr.app" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string macosAsr" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName macosAsr" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$PLIST"

chmod +x "$APP/Contents/MacOS/$APP_NAME"

# 优先用稳定证书 macosAsr Local（rebuild 后辅助功能授权不失效）
# 没有时 fallback 到 ad-hoc（首次或新机器）
SIGN_IDENTITY="macosAsr Local"
sign_with_timeout() {
  local pid
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>&1 &
  pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 20 ]; then
      kill -9 "$pid" 2>/dev/null
      pkill -f SecurityAgent 2>/dev/null || true
      echo "[warn] codesign hung >10s (likely keychain ACL prompt)"
      return 124
    fi
    sleep 0.5
  done
  wait "$pid"
  return $?
}

if command -v codesign >/dev/null 2>&1; then
  if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    if sign_with_timeout; then
      echo "Signed with: $SIGN_IDENTITY"
    else
      echo "[warn] fallback to ad-hoc — run ./scripts/create_codesign_cert.sh first"
      echo "       to set keychain ACL once and avoid this"
      codesign --force --deep --sign - "$APP" 2>/dev/null || true
    fi
  else
    echo "[info] cert '$SIGN_IDENTITY' not found, using ad-hoc"
    echo "[hint] run ./scripts/create_codesign_cert.sh to create stable cert"
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
  fi
fi
echo "Built: $APP"
echo "Run: open --env MACOSASR_ROOT=$ROOT \"$APP\""
