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
echo "[setup] system dependency (if mic fails): brew install portaudio"
echo "[setup] activate: source .venv/bin/activate"
echo "[setup] PYTHONPATH: export PYTHONPATH=\"$ROOT:\${PYTHONPATH:-}\""
