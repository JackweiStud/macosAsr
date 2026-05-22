#!/usr/bin/env bash
# 在桌面创建 macosAsr.app 启动器（一键启动，自动设置 MACOSASR_ROOT）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="${HOME}/Desktop/macosAsr.app"
MAIN_APP="$ROOT/MacApp/build/macosAsrApp.app"

if [[ ! -d "$MAIN_APP" ]]; then
  echo "[install] 未找到 $MAIN_APP，先构建…"
  "$ROOT/scripts/build_macapp.sh"
fi

rm -rf "$DESKTOP"
mkdir -p "$DESKTOP/Contents/MacOS" "$DESKTOP/Contents/Resources"
"$ROOT/scripts/build_icon.sh"

cat > "$DESKTOP/Contents/MacOS/macosAsr" <<EOF
#!/bin/bash
exec "${ROOT}/scripts/launch_macapp.sh"
EOF
chmod +x "$DESKTOP/Contents/MacOS/macosAsr"
cp "$ROOT/MacApp/Assets/AppIcon.icns" "$DESKTOP/Contents/Resources/AppIcon.icns"

cat > "$DESKTOP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>macosAsr</string>
	<key>CFBundleIdentifier</key>
	<string>com.macosasr.launcher</string>
	<key>CFBundleName</key>
	<string>macosAsr</string>
	<key>CFBundleDisplayName</key>
	<string>macosAsr</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
</dict>
</plist>
EOF

echo "[install] 已创建桌面启动器: $DESKTOP"
echo "[install] 双击即可启动（等价于 ./scripts/launch_macapp.sh）"
