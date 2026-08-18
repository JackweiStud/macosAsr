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

# Quit 后可能残留 socket 文件但 daemon 已不在 → 清掉避免卡在 loading
SOCK="$ROOT/run/macosasr.sock"
if [[ -e "$SOCK" ]] && ! pgrep -f "python.*asr_daemon" >/dev/null 2>&1; then
  rm -f "$SOCK"
  echo "已清理残留 socket（daemon 未运行）"
fi

OPEN_ENV_ARGS=(--env "MACOSASR_ROOT=$ROOT")
if [[ -n "${MACOSASR_CONTEXT:-}" ]]; then
  OPEN_ENV_ARGS+=(--env "MACOSASR_CONTEXT=$MACOSASR_CONTEXT")
fi
if [[ "${MACOSASR_PREVIOUS_FINAL_CONTEXT+x}" == "x" ]]; then
  OPEN_ENV_ARGS+=(--env "MACOSASR_PREVIOUS_FINAL_CONTEXT=$MACOSASR_PREVIOUS_FINAL_CONTEXT")
fi
if [[ "${MACOSASR_PREVIOUS_FINAL_CONTEXT_CHARS+x}" == "x" ]]; then
  OPEN_ENV_ARGS+=(--env "MACOSASR_PREVIOUS_FINAL_CONTEXT_CHARS=$MACOSASR_PREVIOUS_FINAL_CONTEXT_CHARS")
fi
if [[ "${MACOSASR_FINAL_AUDIO_TRIM+x}" == "x" ]]; then
  OPEN_ENV_ARGS+=(--env "MACOSASR_FINAL_AUDIO_TRIM=$MACOSASR_FINAL_AUDIO_TRIM")
fi
if [[ "${MACOSASR_FINAL_TRAILING_SILENCE_KEEP+x}" == "x" ]]; then
  OPEN_ENV_ARGS+=(--env "MACOSASR_FINAL_TRAILING_SILENCE_KEEP=$MACOSASR_FINAL_TRAILING_SILENCE_KEEP")
fi
open "${OPEN_ENV_ARGS[@]}" "$APP"
echo "已启动 macosAsrApp"
echo "首次冷启动约 30s（⏳ → 🎤）；若一直 ⏳ 请看 log/daemon.log"
echo "退出：菜单栏 🎤 ASR → Quit（⌘Q），会同时关闭 asr_daemon"
echo "请看菜单栏右侧是否出现 「🎤 ASR」"
echo "若仍看不到：系统设置 → 控制中心 → 菜单栏自动显示 → 关闭「自动隐藏」或缩短其他图标"
echo "日志: tail -f $ROOT/log/macapp.log"
