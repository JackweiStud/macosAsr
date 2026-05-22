#!/usr/bin/env bash
# Lightweight CI smoke checks (no model load, no GUI).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOSASR_ROOT="$ROOT"
cd "$ROOT"

echo "== ci: swift compile =="
./scripts/test_p0c.sh

echo "== ci: python import =="
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  pip install --upgrade pip
  pip install -r requirements.txt
else
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

python -c "from asr.config import AsrConfig; c = AsrConfig(); assert c.partial_interval_seconds == 0.5"
python -m asr_daemon --help >/dev/null

echo "PASS ci smoke"
