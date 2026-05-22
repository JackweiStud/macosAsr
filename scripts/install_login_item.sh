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
  if [[ ! -d "$ROOT/MacApp/build/macosAsrApp.app" ]]; then
    echo "[login] 未找到 App，先构建…"
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
		<string>/bin/bash</string>
		<string>-lc</string>
		<string>${ROOT}/scripts/launch_macapp.sh</string>
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
  echo "[login] 已安装登录项: $PLIST"
  echo "[login] 下次登录后将自动启动 macosAsr"
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
