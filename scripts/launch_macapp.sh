#!/usr/bin/env bash
# 启动 macosAsrApp（先结束旧实例，设置 MACOSASR_ROOT）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/MacApp/build/macosAsrApp.app"

if [[ ! -d "$APP" ]]; then
  echo "未找到 $APP，先运行: ./scripts/build_macapp.sh"
  exit 1
fi

pkill -x macosAsrApp 2>/dev/null || true
sleep 0.5

open --env MACOSASR_ROOT="$ROOT" "$APP"
echo "已启动 macosAsrApp"
echo "请看菜单栏右侧是否出现 「🎤 ASR」"
echo "若仍看不到：系统设置 → 控制中心 → 菜单栏自动显示 → 关闭「自动隐藏」或缩短其他图标"
echo "日志: tail -f $ROOT/log/macapp.log"
