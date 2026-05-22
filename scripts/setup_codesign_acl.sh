#!/usr/bin/env bash
# 给已存在的 macosAsr Local 私钥设置 ACL，让 codesign 永不再弹窗。
# 仅需运行一次（除非更换 Mac 登录密码或重建证书）。
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if ! security find-certificate -c "macosAsr Local" >/dev/null 2>&1; then
  echo "[setup] 未找到证书 macosAsr Local"
  echo "        请先运行：./scripts/create_codesign_cert.sh"
  exit 1
fi

echo "[setup] 即将弹出对话框输入 Mac 登录密码..."
PASSWORD=$(osascript -e 'tell application "System Events" to display dialog "请输入当前 Mac 登录密码：\n\n用于一次性授权 codesign 访问 macosAsr Local 私钥。\n之后所有 ./scripts/build_macapp.sh 都不会再弹钥匙串提示。" default answer "" with hidden answer with title "macosAsr 证书 ACL 配置"' -e 'text returned of result' 2>/dev/null || true)

if [ -z "$PASSWORD" ]; then
  echo "[setup] 已取消（未输入密码）"
  exit 1
fi

if security set-key-partition-list \
     -S apple-tool:,apple:,codesign: \
     -s -k "$PASSWORD" \
     "$KEYCHAIN" >/dev/null 2>&1; then
  echo "[setup] ✅ ACL 已设置：codesign 将永不再弹窗"
  echo ""
  echo "下一步：./scripts/build_macapp.sh"
else
  echo "[setup] ❌ ACL 设置失败（密码错误？）"
  echo "        手动方案：钥匙串访问 → 我的证书 → macosAsr Local → 展开私钥"
  echo "                  → 双击私钥 → 访问控制 → 允许所有应用程序访问此项 → 保存"
  exit 1
fi
