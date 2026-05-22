#!/usr/bin/env bash
# Create a Desktop launcher (.app) that starts macosAsr via Application Support/launch.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="${HOME}/Desktop/macosAsr.app"
MAIN_APP="$ROOT/MacApp/build/macosAsrApp.app"
SUPPORT_LAUNCHER="${HOME}/Library/Application Support/macosAsr/launch.sh"

"$ROOT/scripts/sync_repo_launcher.sh"

if [[ ! -d "$MAIN_APP" ]]; then
  echo "[install] App not found at $MAIN_APP — building…"
  "$ROOT/scripts/build_macapp.sh"
fi

rm -rf "$DESKTOP"
mkdir -p "$DESKTOP/Contents/MacOS" "$DESKTOP/Contents/Resources"
"$ROOT/scripts/build_icon.sh"

cat > "$DESKTOP/Contents/MacOS/macosAsr" <<EOF
#!/usr/bin/env bash
exec "${SUPPORT_LAUNCHER}"
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

echo "[install] Desktop launcher: $DESKTOP"
echo "[install] Repo path saved: ${HOME}/Library/Application Support/macosAsr/repo_root"
echo "[install] Double-click to start (same as ./scripts/launch_macapp.sh)"
echo "[install] If you move the clone, re-run: ./scripts/install_desktop_shortcut.sh"
