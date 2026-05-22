#!/usr/bin/env bash
# macosAsr Python environment setup (SDD §8.1)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if command -v uv >/dev/null 2>&1; then
  echo "[setup] using uv"
  uv venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  uv pip install -r requirements.txt
else
  echo "[setup] using python3 -m venv"
  python3 -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  pip install --upgrade pip
  pip install -r requirements.txt
fi

echo ""
echo "[setup] done."
echo ""
echo "系统依赖（若麦克风失败）："
echo "  brew install portaudio"
echo ""
echo "下一步："
echo "  ./scripts/create_codesign_cert.sh   # 首次，稳定签名"
echo "  ./scripts/build_macapp.sh"
echo "  ./scripts/launch_macapp.sh"
echo ""
echo "详见 README.md「第一次使用」"
