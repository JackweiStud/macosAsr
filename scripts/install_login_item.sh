#!/usr/bin/env bash
# 注册/移除登录项：用户登录 macOS 后自动启动 macosAsr
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="${HOME}/Library/LaunchAgents/com.macosasr.app.plist"
LABEL="com.macosasr.app"

usage() {
  cat <<EOF
用法:
  $0 install    登录时自动启动 macosAsr（LaunchAgent）
  $0 uninstall  移除登录项

说明:
  - 调用 ${ROOT}/scripts/launch_macapp.sh
  - 与桌面启动器、命令行启动方式等价
EOF
}

install_item() {
  "$ROOT/scripts/sync_repo_launcher.sh"
  LAUNCHER="${HOME}/Library/Application Support/macosAsr/launch.sh"

  if [[ ! -d "$ROOT/MacApp/build/macosAsrApp.app" ]]; then
    echo "[login] App not found — building…"
    "$ROOT/scripts/build_macapp.sh"
  fi

  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${LAUNCHER}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "[login] Installed login item: $PLIST"
  echo "[login] macosAsr will start on next login"
  echo "[login] If you move the clone, re-run: $0 install"
}

uninstall_item() {
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  rm -f "$PLIST"
  echo "[login] 已移除登录项"
}

case "${1:-}" in
  install) install_item ;;
  uninstall) uninstall_item ;;
  *) usage; exit 1 ;;
esac
